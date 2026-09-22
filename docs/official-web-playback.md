# Official web playback experiment

Historical experiment: the user subsequently requested the original native UI.
The visible web page and its preference were removed. The follow-up is described
in `native-browser-transport.md`; the APK here remains a separate comparison
artifact. Its smooth playback result must not be attributed to the new adapter.

## Scope

This experiment addresses the user's report that overseas 1080P playback still
stalls despite the earlier adaptive CDN/transport changes. It does not claim
that those historical measurements apply to this phone or today's network.

PiliPlus already calls the official `/x/player/wbi/playurl` endpoint. Merely
renaming that backend or copying a User-Agent cannot reproduce the official
app's proprietary playback stack. This alternative runs the actual official
desktop video page in Android's installed Chromium WebView. The site's code
handles playurl, media requests and rendition selection. Neither the native
mpv reader nor the adaptive loopback bridge participates in this mode.

## Usage

- Android: Settings > Playback > 官方网页播放（实验）.
- Ordinary UGC videos opened through `PageUtils.toVideoPage` use the mode.
  Live, courses, PGC and local playback retain their existing paths.
- The page header has refresh and 原生播放 (one-time native fallback).
- Fullscreen, quality, subtitles and danmaku use the site's own controls.
  Native gestures, download integration and native background audio do not
  transfer to the web player.
- Existing app login cookies are synchronized using the existing login helper.
  Site login may still be required; no official app data is read or migrated.
- The official metadata's CID-to-page mapping preserves multipart selection.
  An unresolved nonzero CID produces an error instead of playing a wrong part.
- HTTP(S) navigation stays in WebView; app/intent schemes are blocked. Media
  URLs are not intercepted or rewritten. No certificate verification changes.
- Backgrounding pauses HTML media; returning does not force playback.

The installed WebView's Chromium User-Agent is adapted for desktop content,
retaining its actual browser version. This requests the desktop player instead
of the mobile site's app-opening UI; it does not impersonate the native app.

## Build and verification

Use the repository's patched Flutter 3.47.4 SDK, not the older global SDK:

```powershell
$env:PUB_CACHE='E:\pili-pub'
& E:/software/flutter-3.47.4/bin/flutter.bat build apk --no-pub --debug --target-platform android-arm64 --dart-define=PILI_OFFICIAL_WEB=true --dart-define=PILI_NETWORK_DIAGNOSTICS=true --android-project-arg kotlin.incremental=false
```

`PILI_OFFICIAL_WEB=true` enables this experiment by default only if the user
has not saved a preference. Normal builds keep the existing native default.
The debug package is `com.example.piliplus.debug`.

Changed-file analysis: no issues. ARM64 debug APK: builds successfully.
Device: Xiaomi 2210132C / Android 16; WebView 143.0.7499.192.

Diagnostics sample only playback time, paused/ready state, decoded dimensions,
buffer end, HTML media error code and observed waiting event counts/duration.
They do not log cookies, media URLs or page HTML. Waiting counters begin with
the first sampled video element and are not a complete startup trace.

The user reported login complete. The latest diagnostic APK was installed with
`adb install -r`, preserving app data. In the resumed session, automatic approval
rejected the combined ADB activity-launch/UI-dump command as blocked by policy
without a more specific reason. No alternate device-control path was attempted.
The user has been asked to open a video and select ordinary 1080P manually;
filtered, read-only `adb logcat` remains available for playback verification.
## Device playback results (2026-09-22)

The user manually started playback after logging in with an ordinary, non-VIP
account. From 22:21:47.890 to 22:25:27.306 (device log time), the official web
player advanced from 2.954 to 222.350 seconds. All samples reported 1920x1080,
`paused=false`, `readyState=4`, zero observed waiting events, and no HTML media
error. The observation window was 219.416 seconds, with 219.396 seconds of
playback advancement. Once downloading settled, the buffered end was roughly
68-73 seconds ahead. These are the site's own buffering decisions, not changes
to PiliPlus's cache size or adaptive CDN transport.

The user was asked to seek beyond the buffered region; seek recovery has not
yet been verified. No matched native-player or official Android-app A/B was
performed in this session. The diagnostic output does not identify the video;
its author/title were not independently verified. Initial startup precedes the
first sample. Results support smooth 1080P playback for this observed session,
not a guarantee for all videos or overseas networks.

Follow-up through 22:26:42.304 reached 297.349 seconds, still 1920x1080,
zero observed waiting events and no media errors (about five minutes total).

Sanitized samples are in `official-web-playback-samples.json`. Installed APK:
`dist/PiliPlus-official-web-debug.apk`, SHA-256
`b4f10d5b71fc8d57cf341a565f24ead5591cddabe84d6430ba4a85450672585d`.
