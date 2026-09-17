import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/utils/cdn_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final servers = <HttpServer>[];
  final selectors = <CdnSelector>[];
  CdnSelector selector() {
    final value = CdnSelector(userAgent: 'PiliPlus-test');
    selectors.add(value);
    return value;
  }

  Future<String> server(Future<void> Function(HttpRequest) handler) async {
    final value = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(value);
    value.listen((request) async {
      try {
        await handler(request);
      } catch (_) {
        // Tests deliberately cancel sockets while handlers are waiting.
      }
    });
    return 'http://127.0.0.1:${value.port}/stream?private=never-log';
  }

  Future<void> good(HttpRequest request) async {
    expect(request.headers.value('range'), 'bytes=0-262143');
    request.response
      ..statusCode = 206
      ..headers.set('content-range', 'bytes 0-262143/10000000')
      ..contentLength = 262144
      ..add(Uint8List(262144));
    await request.response.close();
  }

  tearDown(() async {
    for (final value in selectors) {
      value.cancel();
    }
    for (final value in servers) {
      await value.close(force: true);
    }
    selectors.clear();
    servers.clear();
  });

  test(
    'rejects ignored Range and chooses a valid backup without URL mutation',
    () async {
      final bad = await server((request) async {
        request.response.statusCode = 200;
        await request.response.close();
      });
      final backup = await server(good);
      expect(await selector().select([bad, backup], fallback: bad), backup);
    },
  );

  test('cached host performance avoids repeating probes', () async {
    var requests = 0;
    final first = await server((request) async {
      requests++;
      await good(request);
    });
    final second = await server((request) async {
      requests++;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await good(request);
    });
    final value = selector();
    expect(await value.select([second, first], fallback: second), first);
    final before = requests;
    expect(await value.select([second, first], fallback: second), first);
    expect(requests, before);
  });

  test('cancel closes pending requests promptly and keeps fallback', () async {
    final never = Completer<void>();
    final first = await server((_) => never.future);
    final second = await server((_) => never.future);
    final value = selector();
    final watch = Stopwatch()..start();
    final result = value.select([first, second], fallback: first);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    value.cancel();
    expect(await result, first);
    expect(watch.elapsedMilliseconds, lessThan(1000));
    never.complete();
  });

  test(
    'deadline bounds a silent server and at most two probes run together',
    () async {
      var active = 0;
      var maximum = 0;
      final urls = <String>[];
      for (var i = 0; i < 4; i++) {
        urls.add(
          await server((request) async {
            active++;
            if (active > maximum) maximum = active;
            await Future<void>.delayed(const Duration(milliseconds: 150));
            await good(request);
            active--;
          }),
        );
      }
      await selector().select(urls, fallback: urls.first);
      expect(maximum, lessThanOrEqualTo(2));
      final never = Completer<void>();
      final silent = await server((_) => never.future);
      final watch = Stopwatch()..start();
      await selector().select([silent, urls.first], fallback: silent);
      expect(watch.elapsedMilliseconds, lessThan(1800));
      never.complete();
    },
  );

  test(
    'recovery bypasses recent cache and excludes the failing host',
    () async {
      final first = await server(good);
      var hits = 0;
      final second = await server((request) async {
        hits++;
        await good(request);
      });
      final value = selector();
      await value.select([first, second], fallback: first);
      final before = hits;
      expect(
        await value.select(
          [first, second],
          fallback: first,
          avoidHost: Uri.parse(first).authority,
        ),
        second,
      );
      expect(hits, before + 1);
    },
  );

  test('filters invalid schemes, deduplicates hosts and caps candidates', () {
    final urls = CdnSelector.candidates([
      'file:///private',
      'bad',
      'https://a/video?token=1',
      'https://a/video?token=2',
      'https://b/v',
      'https://c/v',
      'https://d/v',
      'https://e/v',
    ]);
    expect(urls.length, 4);
    expect(urls.first, 'https://a/video?token=1');
  });
}
