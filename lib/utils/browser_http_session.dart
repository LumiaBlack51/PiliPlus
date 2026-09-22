import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Chromium fetch transport, with no visible page or official player running.
/// Normal CORS, TLS and browser cookie rules remain in force.
class BrowserHttpSession {
  static const _diagnostics = bool.fromEnvironment('PILI_NETWORK_DIAGNOSTICS');
  static bool get enabled =>
      Platform.isAndroid &&
      const bool.fromEnvironment('PILI_BROWSER_TRANSPORT');

  BrowserHttpSession._();

  late final HeadlessInAppWebView _view;
  InAppWebViewController? _controller;
  bool _closed = false;
  int _sequence = 0;

  static Future<BrowserHttpSession> create() async {
    final session = BrowserHttpSession._();
    final ready = Completer<void>();
    final ua = (await InAppWebViewController.getDefaultUserAgent())
        .replaceFirst(RegExp(r'\(Linux; Android[^)]*\)'), '(X11; Linux x86_64)')
        .replaceAll(' Version/4.0', '')
        .replaceAll(' Mobile', '');
    session._view = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: '<!doctype html><meta charset="utf-8"><title>Media transport</title>',
        baseUrl: WebUri('https://www.bilibili.com/'),
        historyUrl: WebUri('https://www.bilibili.com/'),
      ),
      initialSettings: InAppWebViewSettings(
        userAgent: ua,
        javaScriptEnabled: true,
        useShouldOverrideUrlLoading: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      ),
      onWebViewCreated: (controller) => session._controller = controller,
      onLoadStop: (_, _) {
        if (!ready.isCompleted) ready.complete();
      },
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame == true && !ready.isCompleted) {
          ready.completeError(
            const HttpException('Browser initialization failed'),
          );
        }
      },
      shouldOverrideUrlLoading: (_, _) async => NavigationActionPolicy.CANCEL,
    );
    // Attach the timeout/error listener before starting the platform view.
    final initialized = ready.future.timeout(const Duration(seconds: 15));
    try {
      await Future.wait([session._view.run(), initialized]);
      if (_diagnostics) debugPrint('PILI_BROWSER initialized');
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  BrowserFetch fetchRange(String url, int start, int end) {
    if (start < 0 || end < start || end - start + 1 > 4 * 1024 * 1024) {
      throw ArgumentError('Invalid browser range');
    }
    return _fetch(url, start: start, end: end);
  }

  Future<Map<String, dynamic>> fetchPlayUrl(Uri uri) async {
    if (uri.scheme != 'https' ||
        uri.host != 'api.bilibili.com' ||
        uri.path != '/x/player/wbi/playurl') {
      throw ArgumentError('Unexpected playurl endpoint');
    }
    final result = await _fetch(uri.toString()).result;
    if (_diagnostics) {
      debugPrint('PILI_BROWSER playurl status=${result.status}');
    }
    if (result.status != 200) {
      throw HttpException('Browser playurl HTTP ${result.status}');
    }
    return jsonDecode(utf8.decode(result.bytes)) as Map<String, dynamic>;
  }

  BrowserFetch _fetch(String url, {int? start, int? end}) {
    final uri = Uri.parse(url);
    if (_closed || _controller == null) {
      throw StateError('Browser session closed');
    }
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const HttpException('Browser transport requires HTTPS');
    }
    final id = ++_sequence;
    final controller = _controller!;
    var cancelled = false;
    void cancel() {
      if (cancelled || _closed) return;
      cancelled = true;
      unawaited(
        controller
            .evaluateJavascript(
              source: 'window.piliRequests?.get($id)?.abort()',
            )
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }

    final future = () async {
      final response = await controller
          .callAsyncJavaScript(
            arguments: {'url': url, 'start': start, 'end': end, 'id': id},
            functionBody: _fetchScript,
          )
          .timeout(
            const Duration(seconds: 18),
            onTimeout: () {
              cancel();
              throw const HttpException('Browser request timed out');
            },
          );
      if (_closed || cancelled) {
        throw const HttpException('Browser request cancelled');
      }
      if (response?.error != null || response?.value is! Map) {
        // Never include JavaScript errors: they can contain signed media URLs.
        throw const HttpException('Browser fetch failed (network or CORS)');
      }
      final data = response!.value as Map;
      if (data['failure'] != null) {
        if (_diagnostics) {
          debugPrint(
            'PILI_BROWSER fetch failed '
            'kind=${start == null ? "api" : "media"}',
          );
        }
        throw const HttpException('Browser fetch failed (network or CORS)');
      }
      return BrowserResponse(
        data['status'] as int,
        data['range'] as String?,
        base64Decode(data['body'] as String),
      );
    }();
    return BrowserFetch(future, cancel);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _controller?.evaluateJavascript(
        source: 'window.piliRequests?.forEach(c=>c.abort()); window.piliRequests?.clear()',
      );
    } catch (_) {
      /* The platform view may already be gone. */
    }
    _controller = null;
    await _view.dispose();
  }

  static const _fetchScript = r'''
window.piliRequests ??= new Map();
const abort = new AbortController();
window.piliRequests.set(id, abort);
const timer = setTimeout(()=>abort.abort(), 15000);
try {
  const media = start !== null;
  const response = await fetch(url, {
    headers: media ? {Range: `bytes=${start}-${end}`} : {},
    credentials: media ? 'omit' : 'include',
    redirect: 'follow', signal: abort.signal
  });
  const limit = media ? end-start+1 : 2*1024*1024;
  if (response.status !== (media ? 206 : 200)) {
    await response.body?.cancel();
    return {status:response.status, range:null, body:''};
  }
  const reader = response.body.getReader();
  const parts=[]; let size=0;
  while (true) {
    const {done, value} = await reader.read();
    if(done) break;
    size+=value.length;
    if(size>limit) { await reader.cancel(); throw new Error('Oversized response'); }
    parts.push(value);
  }
  const bytes=new Uint8Array(size); let offset=0;
  for(const part of parts) { bytes.set(part,offset); offset+=part.length; }
  let binary='';
  for(let i=0;i<size;i+=32768)
    binary+=String.fromCharCode(...bytes.subarray(i,i+32768));
  return {status:response.status, range:response.headers.get('content-range'),
    body:btoa(binary)};
} catch(_) { return {failure:true}; }
finally { clearTimeout(timer); window.piliRequests.delete(id); }
''';
}

class BrowserResponse {
  const BrowserResponse(this.status, this.contentRange, this.bytes);
  final int status;
  final String? contentRange;
  final Uint8List bytes;
}

class BrowserFetch {
  const BrowserFetch(this.result, this.cancel);
  final Future<BrowserResponse> result;
  final void Function() cancel;
}
