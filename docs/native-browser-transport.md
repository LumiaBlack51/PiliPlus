# Native UI with Chromium transport

The user requested the original PiliPlus UI after the full official web-player
experiment played 1080P smoothly for about five minutes. That experiment is
documented separately; its result is not evidence that this new transport works.

## Implementation

- Restored the original `PageUtils` navigation, playback settings, storage keys
  and preferences. Removed the visible official web-player page. No Flutter
  widgets, native controls, gestures, danmaku or quality menus are replaced.
- `PILI_BROWSER_TRANSPORT=true` enables the Android-only experimental transport.
  Standard builds retain their prior behavior; there is no new visible setting.
- UGC playurl requests use Chromium `fetch` against the existing official WBI
  endpoint with the application's signed parameters and main-account cookies.
  Distinct video/main accounts retain the existing account-aware API request
  path, so browser cookie sharing cannot accidentally select the wrong account.
- A headless WebView loads a minimal local HTML document with the official HTTPS
  base origin. It runs our fetch adapter, not the official website or player.
  There is no hidden video playback, advertisement page or second decoder.
- The selected rendition's original primary media URLs are fetched through
  Chromium, with standard TLS and CORS. Media fetches omit cookies. The browser
  follows server-provided redirects, allowing official primary CDN dispatch.
  It manages its own connections; HTTP/2 or HTTP/3 is not assumed without evidence.
- A tokenized IPv4 loopback bridge supplies those bytes to the existing mpv
  player. It reuses the validated range adapter, not its CDN probes or failover.
  No signed URL rewriting, forced provider, cache enlargement or automatic
  quality downgrade is added. Existing player cache settings remain unchanged.
- Reads have bounded bodies (at most 4 MiB), abortable fetches and a 15-second
  browser deadline. The local player allows 20 seconds. Response ranges,
  byte counts and total lengths are checked before delivery. Seeking cancels
  old reads; disposing/changing media closes the browser session.
- Base64 transfer through the WebView bridge adds CPU and temporary memory
  overhead. A server that does not permit browser CORS or expose Content-Range
  fails explicitly; the adapter does not disable CORS or silently revert to
  the old network stack. Unsupported/manual sources retain their prior path.

This separates webpage-style fetching from the native presentation. It does
not reproduce the official player's ABR, CDN failover or download scheduling.

## Verification

17 tests passed: six new browser-bridge tests plus the eleven existing CDN and
range tests. New coverage includes byte-exact seek ranges, preserving the
selected URL without probing alternatives, malformed responses, and cancelling
outstanding browser work. These unit tests mock Chromium fetch; they do not
establish actual CORS compatibility or device performance.

ARM64 APK built and installed with `adb install -r`, preserving app data.
Artifact: `dist/PiliPlus-native-browser-debug.apk`.
Real-device native playback validation is pending user playback. Device UI
automation was denied earlier; diagnostic log reading remains available.

```powershell
$env:PUB_CACHE='E:\pili-pub'
& E:/software/flutter-3.47.4/bin/flutter.bat build apk --no-pub --debug --target-platform android-arm64 --dart-define=PILI_BROWSER_TRANSPORT=true --dart-define=PILI_NETWORK_DIAGNOSTICS=true --android-project-arg kotlin.incremental=false
```

References:
- https://developer.android.com/develop/ui/views/layout/webapps/load-local-content
- https://inappwebview.dev/docs/webview/headless-in-app-webview/
- https://inappwebview.dev/docs/webview/javascript/injection/
