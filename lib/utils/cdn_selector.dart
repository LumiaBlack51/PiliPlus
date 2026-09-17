import 'dart:async';
import 'dart:io';

/// Small, cancellable range probes. Never rewrites a signed playurl or stores it
/// in the host cache. A session owns its sockets; leaving playback closes them.
class CdnSelector {
  CdnSelector({required this.userAgent, this.log});

  final String userAgent;
  final void Function(String)? log;
  final Set<HttpClient> _clients = {};
  bool _cancelled = false;
  static final Map<String, _Health> _history = {};
  static const _sampleBytes = 256 * 1024;
  static const _deadline = Duration(milliseconds: 1200);

  static List<String> candidates(Iterable<String> urls) {
    final seen = <String>{};
    return urls
        .where((url) {
          final uri = Uri.tryParse(url);
          return uri != null &&
              (uri.scheme == 'https' || uri.scheme == 'http') &&
              uri.host.isNotEmpty &&
              seen.add(uri.authority);
        })
        .take(4)
        .toList();
  }

  void cancel() {
    _cancelled = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }

  void record(String url, double cost) {
    if (!_cancelled && cost.isFinite) {
      _remember(Uri.parse(url).authority, cost, const Duration(seconds: 120));
    }
  }

  static void _remember(String host, double cost, Duration ttl) {
    _history.remove(host);
    _history[host] = _Health(cost, DateTime.now().add(ttl));
    while (_history.length > 64) {
      _history.remove(_history.keys.first);
    }
  }

  Future<String> select(
    Iterable<String> urls, {
    required String fallback,
    String? avoidHost,
    double? maximumCost,
  }) async {
    final all = candidates(urls);
    final choices = all
        .where((url) => Uri.parse(url).authority != avoidHost)
        .toList();
    if (_cancelled || all.length < 2) return fallback;
    final scores = <String, double>{};
    // Two sockets maximum, including audio: callers select the tracks serially.
    for (var i = 0; i < choices.length && !_cancelled; i += 2) {
      await Future.wait(
        choices.skip(i).take(2).map((url) async {
          final key = Uri.parse(url).authority;
          final cached = _history[key];
          scores[url] =
              avoidHost == null &&
                  cached != null &&
                  DateTime.now().isBefore(cached.expires)
              ? cached.cost
              : await _probe(url);
        }),
      );
    }
    if (_cancelled) return fallback;
    var best = fallback;
    var cost = double.infinity;
    for (final entry in scores.entries) {
      if (entry.value < cost) {
        best = entry.key;
        cost = entry.value;
      }
    }
    if (maximumCost != null && cost >= maximumCost) return fallback;
    // Prefer stability when the apparent gain is within measurement noise.
    if ((scores[fallback] ?? double.infinity) <= cost * 1.2 && cost.isFinite) {
      best = fallback;
    }
    log?.call(
      'select host=${Uri.parse(best).host} candidates=${choices.length}',
    );
    return best;
  }

  Future<double> _probe(String url) async {
    final client = HttpClient()..connectionTimeout = _deadline;
    _clients.add(client);
    final watch = Stopwatch()..start();
    final host = Uri.parse(url).authority;
    var bytes = 0;
    var connected = 0;
    var firstByte = 0;
    var expired = false;
    final timer = Timer(_deadline, () {
      expired = true;
      client.close(force: true);
    });
    var cost = double.infinity;
    var cacheable = true;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(_deadline);
      connected = watch.elapsedMicroseconds;
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.userAgentHeader, userAgent)
        ..set(HttpHeaders.refererHeader, 'https://www.bilibili.com')
        ..set(HttpHeaders.rangeHeader, 'bytes=0-${_sampleBytes - 1}');
      final response = await request.close().timeout(_deadline);
      if (response.statusCode != HttpStatus.partialContent ||
          !(response.headers
                  .value(HttpHeaders.contentRangeHeader)
                  ?.startsWith('bytes 0-') ??
              false)) {
        cacheable = false;
        return double.infinity;
      }
      await for (final chunk in response.timeout(_deadline)) {
        if (_cancelled || expired) break;
        firstByte = firstByte == 0 ? watch.elapsedMicroseconds : firstByte;
        bytes += chunk.length;
        if (bytes >= _sampleBytes) break;
      }
      if (!_cancelled && !expired && bytes >= _sampleBytes) {
        final transfer = (watch.elapsedMicroseconds - firstByte).clamp(
          1000,
          1200000,
        );
        // Approximate a 1 MiB request, including DNS/TCP/TLS and TTFB.
        cost = firstByte / 1000 + transfer / 1000 * (1024 * 1024 / bytes);
      }
    } catch (_) {
      // Timeout/cancellation/HTTP failures are deliberately not logged with URL.
    } finally {
      timer.cancel();
      client.close(force: true);
      _clients.remove(client);
      if (!_cancelled) {
        if (cacheable) {
          _remember(host, cost, Duration(seconds: cost.isFinite ? 120 : 30));
        }
        log?.call(
          'probe host=${Uri.parse(url).host} connect_ms=${connected ~/ 1000} '
          'ttfb_ms=${firstByte ~/ 1000} bytes=$bytes total_ms=${watch.elapsedMilliseconds} '
          'ok=${cost.isFinite}',
        );
      }
    }
    return cost;
  }
}

class _Health {
  const _Health(this.cost, this.expires);
  final double cost;
  final DateTime expires;
}
