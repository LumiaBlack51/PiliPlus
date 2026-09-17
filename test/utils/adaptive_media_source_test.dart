import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/utils/adaptive_media_source.dart';

void main() {
  test('low bitrate streams use bounded four-second ranges', () async {
    const size = 512 * 1024;
    final ranges = <int>[];
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      final match = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(request.headers.value('range')!)!;
      final start = int.parse(match[1]!);
      final end = int.parse(match[2]!).clamp(0, size - 1);
      ranges.add(end - start + 1);
      request.response
        ..statusCode = 206
        ..contentLength = end - start + 1;
      request.response.headers.set('content-range', 'bytes $start-$end/$size');
      request.response.add(Uint8List(end - start + 1));
      await request.response.close();
    });
    final source = await AdaptiveMediaSource.create(
      tracks: [
        CdnMediaTrack(
          url: 'http://127.0.0.1:${origin.port}/video',
          candidates: [],
          bitrate: 512 * 1024,
        ),
      ],
      userAgent: 'test',
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(source.url(0)));
      final response = await request.close();
      expect(await response.fold<int>(0, (n, bytes) => n + bytes.length), size);
      expect(ranges, [256 * 1024, 256 * 1024]);
    } finally {
      client.close(force: true);
      await source.close();
      await origin.close(force: true);
    }
  });

  test('mid-stream failure retries the same byte range on a backup', () async {
    const size = 5 * 1024 * 1024;
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final backupRanges = <int>[];
    Future<void> serve(HttpRequest request, bool fail) async {
      final range = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(request.headers.value('range')!)!;
      final start = int.parse(range[1]!);
      final end = int.parse(range[2]!).clamp(0, size - 1);
      if (fail && start >= AdaptiveMediaSource.chunkBytes) {
        request.response.statusCode = 503;
      } else {
        if (!fail) backupRanges.add(start);
        request.response
          ..statusCode = 206
          ..contentLength = end - start + 1;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/$size',
        );
        request.response.add(
          Uint8List.fromList(
            List.generate(end - start + 1, (i) => (start + i) % 251),
          ),
        );
      }
      try {
        await request.response.close();
      } catch (_) {}
    }

    first.listen((r) => serve(r, true));
    second.listen((r) => serve(r, false));
    final a = 'http://127.0.0.1:${first.port}/video';
    final b = 'http://127.0.0.1:${second.port}/video';
    final logs = <String>[];
    final source = await AdaptiveMediaSource.create(
      tracks: [
        CdnMediaTrack(url: a, candidates: [a, b]),
      ],
      userAgent: 'test',
      log: logs.add,
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(source.url(0)));
      request.headers.set('range', 'bytes=0-');
      final response = await request.close();
      var offset = 0;
      await for (final chunk in response) {
        for (final byte in chunk) {
          if (byte != offset % 251) fail('Corrupt byte at $offset');
          offset++;
        }
      }
      expect(offset, size);
      expect(backupRanges, contains(AdaptiveMediaSource.chunkBytes));
      expect(logs.where((e) => e.startsWith('failover')).length, 1);
    } finally {
      client.close(force: true);
      await source.close();
      await first.close(force: true);
      await second.close(force: true);
    }
  });

  test('closing cancels a stalled origin promptly', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>();
    origin.listen((_) => received.complete());
    final source = await AdaptiveMediaSource.create(
      tracks: [
        CdnMediaTrack(url: 'http://127.0.0.1:${origin.port}/v', candidates: []),
      ],
      userAgent: 'test',
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(source.url(0)));
      final result = request.close().then<Object>(
        (r) => r,
        onError: (Object e) => e,
      );
      await received.future;
      final watch = Stopwatch()..start();
      await source.close();
      expect(
        await result.timeout(const Duration(seconds: 1)),
        isA<HttpException>(),
      );
      expect(watch.elapsedMilliseconds, lessThan(1000));
    } finally {
      client.close(force: true);
      await source.close();
      await origin.close(force: true);
    }
  });

  test('unknown local paths are rejected', () async {
    final source = await AdaptiveMediaSource.create(
      tracks: [
        CdnMediaTrack(url: 'http://127.0.0.1:1/video', candidates: []),
      ],
      userAgent: 'test',
    );
    final client = HttpClient();
    try {
      final uri = Uri.parse(source.url(0)).replace(path: '/wrong/0');
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, 404);
      await response.drain<void>();
    } finally {
      client.close(force: true);
      await source.close();
    }
  });

  test(
    'relay preserves byte offsets across a cancelled read and seek',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        final match = RegExp(r'bytes=(\d+)-(\d+)')
            .firstMatch(request.headers.value('range')!)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!).clamp(0, 16000000 - 1);
        request.response
          ..statusCode = 206
          ..contentLength = end - start + 1;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/16000000',
        );
        request.response.add(
          Uint8List.fromList(
            List.generate(end - start + 1, (i) => (start + i) % 251),
          ),
        );
        try {
          await request.response.close();
        } catch (_) {}
      });
      final relay = await AdaptiveMediaSource.create(
        tracks: [
          CdnMediaTrack(
            url: 'http://127.0.0.1:${origin.port}/v',
            candidates: [],
          ),
        ],
        userAgent: 'test',
      );
      final client = HttpClient();
      try {
        var request = await client.getUrl(Uri.parse(relay.url(0)));
        request.headers.set('range', 'bytes=0-');
        var response = await request.close();
        expect(response.statusCode, 206);
        await response.first;
        request = await client.getUrl(Uri.parse(relay.url(0)));
        request.headers.set('range', 'bytes=5000000-5000099');
        response = await request.close();
        expect(response.statusCode, 206);
        expect(
          response.headers.value('content-range'),
          'bytes 5000000-5000099/16000000',
        );
        final body = await response.expand((x) => x).toList();
        expect(body, List.generate(100, (i) => (5000000 + i) % 251));
      } finally {
        client.close(force: true);
        await relay.close();
        await origin.close(force: true);
      }
    },
  );
}
