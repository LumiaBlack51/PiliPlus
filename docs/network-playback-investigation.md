# Android network playback investigation

## Environment

- Upstream `b0e7e4eb16d501bac0688738b0ba18d0fce87640` (2026-09-15), version 2.1.4.
- Previously installed PiliPlus: 2.0.2-8ad130567. Official Bilibili: 9.5.0.
- Physical Android 16 ARM64 device over USB, Wi-Fi. No root, DNS changes,
  certificate interception, or access to the official application's private data.
- Flutter 3.47.4 / Dart 3.13.3 with upstream-required Flutter/material_ui patches.
  Dependency versions remain pinned by the original lockfile.

## Source observations (not causal conclusions)

- Web playurl uses `fnval=4048`; models retain base and backup URLs.
- `VideoUtils.getCdnUrl` selects by URL pattern and preference. Default
  `backupUrl` returns the first matching mirror, without performance comparison.
  Explicit provider settings rewrite the host.
- The settings dialog's speed test is separate from playback selection.
- DASH video/audio are separate EDL streams with desktop UA and Bilibili referer.
- API traffic uses Dio (optionally HTTP/2), media uses libmpv/FFmpeg instead.
- The media-kit fork defaults to `network-timeout=5`. PiliPlus supplies
  `reconnect=1,reconnect_max_retries=2`, a 4 MiB forward cache, 16-second
  read-ahead and 10.667-second demuxer hysteresis.
- Existing recovery reopens the same URL, without candidate failover.

## Initial device measurements

Public sample `BV1fK4y1t7hj`, 1080P. Android curl, serial HTTP range requests,
4-second connection timeout and 12-second total deadline, no account credentials.
These are network measurements, not mpv playback results.

Six 1 MiB probes: DNS 2-29 ms; throughput 1.23-5.01 MB/s. This does not establish
DNS as the bottleneck. For 8 MiB probes beginning at byte 1048576:

| Codec | Candidate | Round 1 MB/s | Round 2 MB/s | Observation |
|---|---|---:|---:|---|
| AVC | Akamai | 0.87 | 0.94 | Both completed |
| AVC | Tencent overseas | 2.37 | 0.67 | Round 2 TTFB 10.30 s, deadline reached |
| HEVC | Akamai | 4.19 | 5.54 | Both completed |
| HEVC | Tencent overseas | 0.22 | 6.87 | Round 1 deadline reached |
| AV1 | Akamai | 1.76 | 7.72 | Both completed |
| AV1 | Tencent overseas | 4.23 | 6.06 | Both completed |

Decimal MB/s includes startup. A deadline is not a server timeout. Ordering and
edge cache state are confounders. The data shows variation across time/resources,
not that a fixed provider or a codec is always slower.

## Diagnostics

- `tool/network_probe.py`: device DNS/TCP/TLS/TTFB/throughput; bounded samples and
  deadlines; no signed URLs saved in results.
- `tool/network_playback_lab.dart`: temporary APK entry point using the pinned
  player and original parameters. Tests 1080P codecs/candidates and seeks to 100s.
  Sanitized `PILI_LAB` events report buffering, cache, position, frame drops.

## Controlled playback results

All tests used the USB-connected Android device on the same Wi-Fi, hardware
video decoding, and the pinned media-kit/mpv build. The HDR source was obtained
through PiliPlus's public playback-address dialog; no credentials were copied.
Signed URLs and personal data are kept out of this repository.

| Case | Observation window | Spontaneous buffer time | Decoder drops |
|---|---:|---:|---:|
| Original network path, 4 MiB cache, 4K HDR HEVC | 180 s | 94.328 s | 0 |
| Original path, 32 MiB cache | 180 s | Persistent late stalls, 80 paused samples | 0 |
| FFmpeg bounded 4 MiB requests, persistent HTTP | 180 s | 31.129 s | 0 |
| FFmpeg bounded 4 MiB requests, fresh HTTP | 180 s | 27.714 s | 0 |
| Same complete video/audio files, local storage | 180 s | 0 s | 0 |
| Dart bounded-read prototype, original hosts, 4 MiB cache | 180 s | 0 s | 0 |
| Production AdaptiveMediaSource, original hosts, 4 MiB cache | 180 s | 0 s | 0 |

The production HDR run reached playback position 258.091 s, including a seek to
100 s after 20 s of observation. Startup buffering was 2.491 s; seek buffering
was 2.220 s. These intentional waits are excluded from spontaneous buffer time.
The original run includes the final unfinished buffer interval. Counts are
computed from timestamped events, not from visible loading animations.

The HDR track is 3840 x 1920 HEVC, approximately 13.9 Mbit/s average. Its largest
5-second segment averages about 3.90 MB/s. Short range tests on its video host
reached 6.2-6.8 MB/s. A long open-ended request later fell to 0.465 MB/s; fresh
4 MiB ranges of the same tail then reached 6.225 MB/s on Tencent overseas and
2.858 MB/s on Akamai. Thus a short host speed test does not reliably predict
continuous playback.

The unmodified lab also played public 1080P AVC, HEVC, and AV1 variants on both
returned providers, approximately 45 s each with a seek, without spontaneous
buffering. A second public video (BV1qM4y1w716) produced 12 successful 4 MiB
range probes: DNS 3.18-5.83 ms, TTFB 34.6-260.2 ms, and 1.35-6.67 MB/s.

The production selector/bridge also completed the three 1080P codec variants
(AVC, HEVC, AV1), 45 seconds each including seeks: zero spontaneous buffers,
zero decoder drops, and zero player errors. These are the API qn=80 renditions;
encoded frame dimensions vary with codec and source aspect ratio.

A subsequent full-app run exposed stalls with fixed 4 MiB ranges on a different
1080P rendition. Failover worked but both requests hit the six-second deadline.
The final implementation therefore scales range size with declared bitrate,
keeping the proven 4 MiB cap for HDR while reducing low-bitrate startup/retry work.

## Full application checks

The complete app was installed and exercised after the lab tests, using the
normal media-kit Android surface (`mediacodec`; the lab used `mediacodec-copy`).
The new CDN preference persisted across APK upgrades and process restarts.

- BV15z4y1Z734 at 1080P H.264 (1920 x 960): over three minutes, a seek to
  101.503 s recovered in 1.493 s. Two real request failures caused automatic
  host changes. A later failed recovery produced one spontaneous 1.977-second
  stall. This is retained as a limitation, not classified as a zero-stall run.
- BV1qM4y1w716 at 1080P H.264 (2048 x 1080): approximately two minutes,
  pause/resume and a seek to 117.262 s (0.081-second buffering), no spontaneous
  stall observed. Switching videos correctly cancelled the previous source.
- Same original 3840 x 1920 HDR HEVC and audio URLs: more than 180 seconds,
  seek to 101.503 s recovered in 2.551 s; zero spontaneous buffers, zero
  decoder drops. Position reached 239.673 s at the final sample. Original
  4 MiB demuxer cache retained. A temporary debug-only helper prefilled the
  existing playback-address dialog because the phone IME transformed long
  typed URLs; it did not alter playback logic. That helper was removed before
  the final build, and its private fixture was deleted from the phone.

Final source checks: the changed Dart files have no analyzer issues, all 11
regression tests pass, and the APK builds successfully. A whole-repository
analysis reports pre-existing informational lints in bundled Flutter widgets
and naming; no analyzer errors or warnings were found. No root, account data
migration, or system DNS changes were required. The previous input method was
restored after UI testing. Temporary media files were removed from the device.

## Interpretation and limits

The reproduced bottleneck is the continuous remote-reading path under player
backpressure and variable delivery performance, most visible at high bitrate.
DNS and decoding were not the limiting factors in these observations. Changing
only CDN names, demuxer hysteresis, cache size, or FFmpeg request_size did not
reliably cure it. Completing bounded downloads independently of mpv's read
cadence did. This isolates a useful application-level fix; it does not identify
which remote queue, congestion algorithm, TLS implementation, or middlebox
causes the degradation. Runs are sequential and network conditions vary.

The official Bilibili app played the same HDR-titled video smoothly for about
three minutes, but its quality menu showed automatic 1080P. Selecting HDR
required membership in that official-app session. No payment, account transfer,
root, TLS interception, or security bypass was attempted. Consequently there is
no matched official-app 4K HDR A/B, and no evidence to assert its CDN, DNS,
transport protocol, or buffering implementation. Video title is not proof of
actual playback quality.

## Implementation

A new opt-in CDN entry, `自动优选（海外网络）`, retains the existing default and
all manual providers. It uses only the selected rendition's actual base and
backup URLs; it does not rewrite signed URLs or substitute CDN IPs.

- Up to four distinct authorities, two concurrent 256 KiB range probes,
  1.2-second absolute deadline. Score includes connection/first-byte delay and
  estimated transfer time. Host-only cache: 120 s success, 30 s failure, 64 hosts.
- Session-scoped IPv4 loopback HTTP bridge with an unguessable URL token and
  fixed track allowlist. At most one active transfer per video/audio track.
- Complete approximately four seconds of encoded video per upstream request,
  clamped to 256 KiB..4 MiB, before handing bytes to mpv. Unknown-bitrate
  tracks retain a 4 MiB bound.
  Validate status, Content-Range, object size and received byte count.
  No redirects, credential copying, disk media cache, or whole-file downloads.
- Six-second range deadline; three-second connection deadline. Failed ranges
  can retry once at the identical byte offset on a healthy backup. Three
  consecutive slow chunks can trigger a fresh probe; 30-second switch cooldown
  and a 20% improvement threshold limit oscillation. Audio/video probes serialize.
- Seeks cancel superseded reads; changing media/disposal closes clients/server.
  Failover occurs within the stream, without reopening the player or losing
  position. Manual URL edits and audio-CDN opt-out preserve their chosen host.
- Original demuxer/cache settings remain unchanged. Only the loopback network
  timeout becomes 20 s to cover the bounded upstream retry path; direct sources
  retain 5 s. No system DNS or device-global network changes.
- `PILI_CDN` logs contain host/timings only. More detailed 5-second `PILI_NET`
  playback metrics require `--dart-define=PILI_NETWORK_DIAGNOSTICS=true`.

Tradeoffs: more HTTP/TLS connections, temporary bounded body copies in Dart,
probe traffic (up to 1 MiB per uncached track), and additional startup/seek
latency. The optional mode is intended for this observed overseas failure;
very slow networks, non-range servers, expired URLs, and all-candidate outages
still require normal error handling. No automatic quality reduction is added.
Host history currently expires by time rather than network identity.

## Validation and reproduction

Regression tests cover range validation, probe cancellation/deadlines/concurrency,
host deduplication/cache, recovery reprobes, byte-exact midstream failover,
closing a stalled origin, loopback allowlisting, cancelled-read seek offsets,
and low-bitrate range sizing. All 11 tests pass.
Run:

```text
flutter test test/utils/cdn_selector_test.dart test/utils/adaptive_media_source_test.dart
flutter build apk --debug --target-platform android-arm64 --dart-define=PILI_NETWORK_DIAGNOSTICS=true
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

The debug application ID is separate from the existing installation, preserving
its account and settings. Select the new CDN entry in the debug app to enable it.
The Windows build used `--android-project-arg kotlin.incremental=false` because
the SDK/pub cache and project were on different drives; this is a build-host
workaround, not a runtime source change. Apply the upstream Flutter patches
before building with this SDK. Original dependency lockfile is unchanged.

`tool/network_playback_lab.dart` is an alternate diagnostic entry point, not the
shipping UI. It accepts a temporary private `files/lab-playurl.json` with API
`data.dash` and optional `data._lab` settings (`quality`, `seconds`, `adaptive`,
`relay`, `cacheMiB`). Remove that temporary file after testing. Setting `relay`
uses fixed original hosts to isolate the transport change; `adaptive` additionally
enables candidate selection. `tool/network_capture.py` captures sanitized tags,
and `tool/network_lab_summary.py` separates startup/seek from spontaneous stalls.

Protocol references: [FFmpeg HTTP options](https://ffmpeg.org/ffmpeg-protocols.html#http)
and [mpv options](https://mpv.io/manual/stable/#options). The tested native library
reported mpv v0.41.0-dirty / FFmpeg n9.0.1. Trace confirmed FFmpeg's bounded Range
headers were actually sent; those negative tests were not caused by an ignored
request_size option.

## Delivered artifact

`dist/PiliPlus-overseas-debug.apk` (Android ARM64 debug, version 2.1.4), installed
with `adb install -r`; original non-debug application/account preserved. The
adaptive preference is enabled in the debug app. SHA-256:
`7a40b2d2f69c083183ec934c344e148f724432055312b302fc9b3033d529cb5c`.
The final APK's follow-up 1080P run also recovered from a real 3-second socket
connection timeout by switching Akamai to Tencent overseas; more than one
minute of subsequent playback advanced without a spontaneous buffer event.

Production changes are confined to the two new network utilities,
`pages/video/controller.dart`, `plugin/pl_player/controller.dart`, its
`models/data_source.dart`, `models/common/video/cdn_type.dart`,
`pages/setting/widgets/select_dialog.dart`, and `utils/video_utils.dart`.
Diagnostic tools, regression tests, and this report are separate. No dependency
upgrade, persistent URL database, system DNS configuration, or CDN-IP constant
was introduced. Machine-readable sanitized lab results are adjacent in
`network-playback-results.json`.

The most useful next step is a measured adaptive-quality policy when every
candidate remains slower than the selected rendition, with network-change-aware
health-cache invalidation and longer multi-network validation. The current
change deliberately does not silently lower the user's chosen quality.
