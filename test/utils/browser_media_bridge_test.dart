import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/utils/adaptive_media_source.dart';
import 'package:PiliPlus/utils/browser_http_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'browser bridge preserves bytes and seek offsets without CDN probes',
    () async {
      const size = 900000;
      final requested = <int>[];
      var disposed = false;
      final source = await AdaptiveMediaSource.create(
        tracks: [
          CdnMediaTrack(
            url: 'https://origin.invalid/signed',
            candidates: ['https://backup.invalid/unused'],
            bitrate: 512 * 1024,
          ),
        ],
        userAgent: 'test',
        readBrowserRange: (url, start, end) {
          expect(url, 'https://origin.invalid/signed');
          requested.add(start);
          end = end.clamp(0, size - 1);
          return BrowserFetch(
            Future.value(
              BrowserResponse(
                206,
                'bytes $start-$end/$size',
                Uint8List.fromList(
                  List.generate(end - start + 1, (i) => (start + i) % 251),
                ),
              ),
            ),
            () {},
          );
        },
        closeBrowser: () async {
          disposed = true;
        },
      );
      final client = HttpClient();
      try {
        await source.initialize();
        final request = await client.getUrl(Uri.parse(source.url(0)));
        request.headers.set('range', 'bytes=100000-800000');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(
          response.headers.value('content-range'),
          'bytes 100000-800000/$size',
        );
        var offset = 100000;
        await for (final bytes in response) {
          for (final byte in bytes) {
            if (byte != offset % 251) fail('Corrupt byte at $offset');
            offset++;
          }
        }
        expect(offset, 800001);
        expect(requested, [100000, 362144, 624288]);
      } finally {
        client.close(force: true);
        await source.close();
      }
      expect(disposed, isTrue);
    },
  );

  for (final invalid in [
    BrowserResponse(200, 'bytes 0-3/4', Uint8List(4)),
    BrowserResponse(206, null, Uint8List(4)),
    BrowserResponse(206, 'bytes 1-4/5', Uint8List(4)),
    BrowserResponse(206, 'bytes 0-3/4', Uint8List(3)),
  ]) {
    test(
      'browser bridge rejects malformed response ${invalid.status}/${invalid.contentRange}/${invalid.bytes.length}',
      () async {
        var calls = 0;
        final source = await AdaptiveMediaSource.create(
          tracks: [
            CdnMediaTrack(
              url: 'https://origin.invalid/video',
              candidates: ['https://backup.invalid/not-used'],
            ),
          ],
          userAgent: 'test',
          readBrowserRange: (_, _, _) {
            calls++;
            return BrowserFetch(Future.value(invalid), () {});
          },
        );
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(Uri.parse(source.url(0))))
              .close();
          await response.drain<void>();
          expect(response.statusCode, 502);
          expect(calls, 1); // No implicit host switch or alternate transport.
        } finally {
          client.close(force: true);
          await source.close();
        }
      },
    );
  }

  test('closing cancels an outstanding browser read', () async {
    final started = Completer<void>();
    final pending = Completer<BrowserResponse>();
    var cancelled = false;
    final source = await AdaptiveMediaSource.create(
      tracks: [
        CdnMediaTrack(url: 'https://origin.invalid/video', candidates: []),
      ],
      userAgent: 'test',
      readBrowserRange: (_, _, _) {
        started.complete();
        return BrowserFetch(pending.future, () {
          cancelled = true;
          if (!pending.isCompleted) {
            pending.completeError(const HttpException('Cancelled'));
          }
        });
      },
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(source.url(0)));
      final response = request.close().then<void>((r) async {
        await r.drain<void>();
      }, onError: (Object _) {});
      await started.future;
      await source.close();
      await response.timeout(const Duration(seconds: 2));
      expect(cancelled, isTrue);
    } finally {
      client.close(force: true);
      await source.close();
    }
  });
}
