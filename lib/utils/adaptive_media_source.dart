import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/utils/cdn_selector.dart';

class CdnMediaTrack {
  CdnMediaTrack({required this.url, required this.candidates, this.bitrate});
  String url;
  final List<String> candidates;
  final int? bitrate;
  int? length;
  int slowChunks = 0;
  DateTime? lastSwitch;
}

/// A session-scoped, loopback-only bridge for seekable DASH tracks.
///
/// Fetch each bounded range completely before allowing player backpressure to
/// pause reading. This avoids keeping a remote download stalled behind mpv's
/// small demuxer cache. At most two tracks fetch bounded 4 MiB bodies (plus transient copies).
/// Signed URLs never leave the allowlist; local URLs contain an opaque token.
class AdaptiveMediaSource {
  AdaptiveMediaSource._(this._server, this.tracks, this.userAgent, this.log)
    : _selector = CdnSelector(userAgent: userAgent, log: log);

  static const chunkBytes = 4 * 1024 * 1024;
  static const _deadline = Duration(seconds: 6);
  static const _cooldown = Duration(seconds: 30);
  final HttpServer _server;
  final List<CdnMediaTrack> tracks;
  final String userAgent;
  final void Function(String)? log;
  final CdnSelector _selector;
  final Map<int, _Transfer> _active = {};
  final String _token = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  bool _closed = false;
  Future<void>? _selection;

  static Future<AdaptiveMediaSource> create({
    required List<CdnMediaTrack> tracks,
    required String userAgent,
    void Function(String)? log,
  }) async {
    if (tracks.isEmpty || tracks.length > 2) {
      throw ArgumentError('Expected 1-2 tracks');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final source = AdaptiveMediaSource._(server, tracks, userAgent, log);
    server.listen((request) => unawaited(source._handle(request)));
    return source;
  }

  String url(int index) => 'http://127.0.0.1:${_server.port}/$_token/$index';

  Future<void> initialize() async {
    for (final track in tracks) {
      if (_closed) return;
      track.url = await _selector.select(track.candidates, fallback: track.url);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _selector.cancel();
    for (final transfer in _active.values) {
      transfer.cancel();
    }
    _active.clear();
    await _server.close(force: true);
  }

  Future<bool> _switch(CdnMediaTrack track, {double? maximumCost}) async {
    if (_closed ||
        CdnSelector.candidates(track.candidates).length < 2 ||
        (track.lastSwitch != null &&
            DateTime.now().difference(track.lastSwitch!) < _cooldown)) {
      return false;
    }
    // Audio/video recovery must not create two independent probe batches.
    final previous = _selection;
    final done = Completer<void>();
    _selection = done.future;
    await previous;
    try {
      if (_closed) return false;
      track.lastSwitch = DateTime.now();
      final next = await _selector.select(
        track.candidates,
        fallback: track.url,
        avoidHost: Uri.parse(track.url).authority,
        maximumCost: maximumCost,
      );
      if (_closed || next == track.url) return false;
      log?.call(
        'failover from=${Uri.parse(track.url).host} to=${Uri.parse(next).host}',
      );
      track
        ..url = next
        ..slowChunks = 0;
      return true;
    } finally {
      done.complete();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    _Transfer? transfer;
    int? index;
    try {
      final parts = request.uri.pathSegments;
      index = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (_closed ||
          parts.length != 2 ||
          parts[0] != _token ||
          index == null ||
          index < 0 ||
          index >= tracks.length ||
          request.method != 'GET') {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      final track = tracks[index];
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      if (range != null && match == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return;
      }
      var offset = match == null ? 0 : int.parse(match[1]!);
      int? end = match == null || match[2]!.isEmpty
          ? null
          : int.parse(match[2]!);
      if ((end != null && end < offset) ||
          (track.length != null && offset >= track.length!)) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        if (track.length != null) {
          request.response.headers.set(
            'content-range',
            'bytes */${track.length}',
          );
        }
        return;
      }
      _active[index]?.cancel();
      transfer = _Transfer();
      _active[index] = transfer;
      request.response.persistentConnection = false;
      while (!_closed &&
          !transfer.cancelled &&
          (end == null || offset <= end)) {
        // About four seconds of encoded media, bounded independently of mpv's
        // cache. Low bitrate streams should not wait for a full 4 MiB body.
        final bytesPerRange = track.bitrate == null || track.bitrate! <= 0
            ? chunkBytes
            : (track.bitrate! ~/ 2).clamp(256 * 1024, chunkBytes);
        final chunkEnd = min(
          offset + bytesPerRange - 1,
          end ?? 0x7fffffffffffffff,
        );
        late _Chunk chunk;
        for (var attempt = 0; ; attempt++) {
          try {
            chunk = await _read(track, transfer, offset, chunkEnd);
            break;
          } catch (_) {
            if (_closed ||
                transfer.cancelled ||
                attempt != 0 ||
                !await _switch(track)) {
              rethrow;
            }
          }
        }
        if (_closed || transfer.cancelled) return;
        end = min(end ?? chunk.total - 1, chunk.total - 1);
        if (transfer.socket == null) {
          request.response
            ..statusCode = range == null
                ? HttpStatus.ok
                : HttpStatus.partialContent
            ..contentLength = end - offset + 1;
          request.response.headers
            ..set('content-type', 'video/mp4')
            ..set('accept-ranges', 'bytes');
          if (range != null) {
            request.response.headers.set(
              'content-range',
              'bytes $offset-$end/${chunk.total}',
            );
          }
          transfer.socket = await request.response.detachSocket();
          final current = transfer;
          transfer.socket!.listen(
            (_) {},
            onDone: current.cancel,
            onError: (_) => current.cancel(),
          );
        }
        transfer.socket!.add(chunk.bytes);
        await transfer.socket!.flush();
        offset += chunk.bytes.length;
        if (track.slowChunks >= 3 && !transfer.cancelled) {
          track.slowChunks = 0;
          await _switch(track, maximumCost: chunk.cost * 0.8);
        }
      }
      await transfer.socket?.close();
      transfer.socket = null;
    } catch (_) {
      if (transfer?.socket == null) {
        try {
          request.response.statusCode = HttpStatus.badGateway;
        } catch (_) {}
      }
      if (!_closed && transfer?.cancelled != true) {
        log?.call('range failed track=$index');
      }
      transfer?.cancel();
    } finally {
      if (_active[index] == transfer) _active.remove(index);
      transfer?.cancel();
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<_Chunk> _read(
    CdnMediaTrack track,
    _Transfer transfer,
    int start,
    int end,
  ) async {
    // A client belongs to one range, so timed-out sockets cannot leak into retry.
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 3)
      ..maxConnectionsPerHost = 1;
    transfer.client = client;
    final watch = Stopwatch()..start();
    final timer = Timer(_deadline, () => client.close(force: true));
    var received = 0;
    var status = 0;
    var expected = 0;
    try {
      final request = await client
          .getUrl(Uri.parse(track.url))
          .timeout(_deadline);
      request
        ..persistentConnection = false
        ..followRedirects = false;
      request.headers
        ..set('user-agent', userAgent)
        ..set('referer', 'https://www.bilibili.com')
        ..set('accept-encoding', 'identity')
        ..set('range', 'bytes=$start-$end');
      final response = await request.close().timeout(_deadline);
      status = response.statusCode;
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
          .firstMatch(response.headers.value('content-range') ?? '');
      if (response.statusCode != 206 ||
          range == null ||
          int.parse(range[1]!) != start ||
          int.parse(range[2]!) > end ||
          int.parse(range[2]!) < start ||
          int.parse(range[3]!) <= int.parse(range[2]!) ||
          (track.length != null && track.length != int.parse(range[3]!))) {
        throw const HttpException('Invalid range response');
      }
      final body = BytesBuilder(copy: false);
      expected = int.parse(range[2]!) - start + 1;
      await for (final chunk in response) {
        if (_closed || transfer.cancelled) {
          throw const HttpException('Cancelled');
        }
        body.add(chunk);
        received += chunk.length;
        if (body.length > chunkBytes) {
          throw const HttpException('Oversized range');
        }
      }
      final bytes = body.takeBytes();
      if (bytes.length != int.parse(range[2]!) - start + 1) {
        throw const HttpException('Incomplete range');
      }
      track.length = int.parse(range[3]!);
      final seconds = max(watch.elapsedMicroseconds / 1000000, 0.001);
      final rate = bytes.length / seconds;
      final cost = 1024 * 1024 / rate * 1000;
      _selector.record(track.url, cost);
      track.slowChunks =
          track.bitrate != null && rate * 8 < track.bitrate! * 0.8
          ? track.slowChunks + 1
          : 0;
      return _Chunk(bytes, track.length!, cost);
    } catch (error) {
      if (!_closed && !transfer.cancelled) {
        final reason =
            error is HttpException &&
                const [
                  'Invalid range response',
                  'Incomplete range',
                  'Oversized range',
                ].contains(error.message)
            ? error.message
            : error.runtimeType.toString();
        log?.call(
          'range abort host=${Uri.parse(track.url).host} status=$status '
          'bytes=$received expected=$expected reason=$reason '
          'elapsed_ms=${watch.elapsedMilliseconds}',
        );
      }
      rethrow;
    } finally {
      timer.cancel();
      client.close(force: true);
      if (transfer.client == client) transfer.client = null;
    }
  }
}

class _Chunk {
  const _Chunk(this.bytes, this.total, this.cost);
  final Uint8List bytes;
  final int total;
  final double cost;
}

class _Transfer {
  HttpClient? client;
  Socket? socket;
  bool cancelled = false;
  void cancel() {
    cancelled = true;
    client?.close(force: true);
    socket?.destroy();
  }
}
