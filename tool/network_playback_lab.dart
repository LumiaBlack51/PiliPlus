// Temporary, account-free real-device diagnostic entry point.
// flutter run -t tool/network_playback_lab.dart --dart-define=LAB_SECONDS=45
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/adaptive_media_source.dart';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const MaterialApp(home: Lab()));
}

class Lab extends StatefulWidget {
  const Lab({super.key});
  @override
  State<Lab> createState() => _LabState();
}

class _LabState extends State<Lab> {
  Player? player;
  VideoController? video;
  String status = 'Preparing diagnostic playback';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  bool cancelled = false;
  AdaptiveMediaSource? relay;
  String label = '';

  void report(String event, Map<String, Object?> values) {
    debugPrint(
      'PILI_LAB ${jsonEncode({'event': event, 'test': label, ...values})}',
    );
  }

  Future<Map<String, dynamic>> api(
    String path,
    Map<String, String> query,
  ) async {
    final request = await client.getUrl(
      Uri.https('api.bilibili.com', path, query),
    );
    request.headers.set('user-agent', BrowserUa.pc);
    request.headers.set('referer', 'https://www.bilibili.com');
    final response = await request.close().timeout(const Duration(seconds: 12));
    final result = jsonDecode(
      await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 12)),
    ) as Map<String, dynamic>;
    if (result['code'] != 0) throw StateError('API code ${result['code']}');
    return result['data'] as Map<String, dynamic>;
  }

  @override
  void initState() {
    super.initState();
    run();
  }

  Future<void> run() async {
    try {
      await WakelockPlus.enable();
      final p = await Player.create(
        configuration: const PlayerConfiguration(
          logLevel: MPVLogLevel.warn,
          options: {
            'video-sync': 'display-resample',
            'stream-lavf-o': 'reconnect=1,reconnect_max_retries=2',
          },
        ),
      );
      player = p;
      video = await VideoController.create(
        p,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: true,
          androidAttachSurfaceAfterVideoParameters: false,
        ),
      );
      p.setMediaHeader(
        userAgent: BrowserUa.pc,
        referer: 'https://www.bilibili.com',
      );
      p.stream.buffering.listen(
        (value) => report('buffering', {
          'active': value,
          'position_ms': p.state.position.inMilliseconds,
          'buffer_ms': p.state.buffer.inMilliseconds,
        }),
      );
      p.stream.error.listen(
        (value) => report('error', {
          'message': value.replaceAll(RegExp(r'https?://\S+'), '[url]'),
        }),
      );
      p.stream.log.listen((entry) {
        if (RegExp(
          'timeout|reconnect|failed|error|Range:|Content-Range:|HTTP/[12]|not found',
          caseSensitive: false,
        ).hasMatch(entry.text)) {
          report('mpv', {
            'level': entry.level,
            'prefix': entry.prefix,
            'message': entry.text
                .split('\n')
                .where(
                  (line) => !RegExp(
                    r'GET |POST |Host:|User-Agent:|Accept:|Referer:|Cookie:',
                    caseSensitive: false,
                  ).hasMatch(line),
                )
                .join('\n')
                .replaceAll(RegExp(r'https?://\S+'), '[url]'),
          });
        }
      });
      if (mounted) setState(() {});
      const bvid = String.fromEnvironment(
        'LAB_BVID',
        defaultValue: 'BV1fK4y1t7hj',
      );
      final input = File(
        '${(await getApplicationSupportDirectory()).path}/lab-playurl.json',
      );
      final Map<String, dynamic> data;
      if (input.existsSync()) {
        data =
            (jsonDecode(await input.readAsString())
                    as Map<String, dynamic>)['data']
                as Map<String, dynamic>;
      } else {
        final info = await api('/x/web-interface/view', {'bvid': bvid});
        data = await api('/x/player/playurl', {
          'bvid': bvid,
          'cid': '${info['cid']}',
          'qn': '80',
          'fnval': '4048',
          'fourk': '1',
          'try_look': '1',
        });
      }
      final dash = data['dash'] as Map<String, dynamic>;
      final settings = data['_lab'] as Map<String, dynamic>? ?? {};
      final cacheMiB = (settings['cacheMiB'] as int? ?? 4).clamp(1, 64);
      if (settings['requestMiB'] case final int requestMiB) {
        final bytes = requestMiB.clamp(1, 8) * 1024 * 1024;
        p.setProperty(
          'stream-lavf-o',
          'reconnect=1,reconnect_max_retries=2,request_size=$bytes,short_seek_size=$bytes,multiple_requests=${settings['keepAlive'] ?? 1}',
        );
      }
      report('versions', {
        'mpv': p.getProperty('mpv-version'),
        'ffmpeg': p.getProperty('ffmpeg-version'),
      });
      final tracks = (dash['video'] as List)
          .cast<Map<String, dynamic>>()
          .where((e) => e['id'] == (settings['quality'] ?? 80))
          .toList();
      final audio = (dash['audio'] as List).first as Map<String, dynamic>;
      final audioUrl = (audio['baseUrl'] ?? audio['base_url']) as String;
      for (final track in tracks) {
        final urls = <String>[
          (track['baseUrl'] ?? track['base_url']) as String,
          ...((track['backupUrl'] ?? track['backup_url'] ?? []) as List)
              .cast<String>(),
        ];
        for (final url in urls.take(settings['adaptive'] == true ? 1 : 3)) {
          if (settings['host'] != null &&
              Uri.parse(url).host != settings['host']) {
            continue;
          }
          if (cancelled) return;
          label = '${track['codecs']}@${Uri.parse(url).host}';
          if (mounted) setState(() => status = label);
          report('start', {
            'bandwidth': track['bandwidth'],
            'quality': track['id'],
            'cacheMiB': cacheMiB,
          });
          if (settings['relay'] == true || settings['adaptive'] == true) {
            relay = await AdaptiveMediaSource.create(
              tracks: [
                CdnMediaTrack(
                  url: url,
                  candidates: settings['adaptive'] == true ? urls : [url],
                  bitrate: track['bandwidth'] as int?,
                ),
                CdnMediaTrack(
                  url: audioUrl,
                  candidates: settings['adaptive'] == true
                      ? [
                          audioUrl,
                          ...((audio['backupUrl'] ?? audio['backup_url'] ?? [])
                                  as List)
                              .cast<String>(),
                        ]
                      : [audioUrl],
                ),
              ],
              userAgent: BrowserUa.pc,
              log: (message) => report('cdn', {'message': message}),
            );
            await relay!.initialize();
            p.setProperty('network-timeout', '20');
          }
          Future<void> open(Duration? position) async {
            final selectedVideo = relay?.url(0) ?? url;
            final selectedAudio = relay?.url(1) ?? audioUrl;
            final edl =
                (settings['videoOnly'] == true ||
                    settings['externalAudio'] == true)
                ? selectedVideo
                : 'edl://!no_chapters;%${selectedVideo.length}%$selectedVideo;'
                      '!new_stream;!no_chapters;%${selectedAudio.length}%$selectedAudio';
            await p.open(
              Media(
                edl,
                start: position,
                extras: {
                  if (settings['externalAudio'] == true)
                    'audio-files-append': selectedAudio,
                  'cache': 'yes',
                  'cache-secs': '16',
                  'demuxer-hysteresis-secs':
                      '${settings['hysteresis'] ?? 10.667}',
                  'demuxer-max-bytes': '${cacheMiB * 1024 * 1024}',
                  'demuxer-max-back-bytes': '4194304',
                },
              ),
              play: true,
            );
          }

          await open(null);
          final seconds =
              (settings['seconds'] as int? ??
                      const int.fromEnvironment(
                        'LAB_SECONDS',
                        defaultValue: 45,
                      ))
                  .clamp(10, 300);
          for (int i = 0; i < seconds && !cancelled; i++) {
            await Future<void>.delayed(const Duration(seconds: 1));
            final values = <String, Object?>{'elapsed': i + 1};
            for (final name in [
              'time-pos',
              'paused-for-cache',
              'demuxer-cache-duration',
              'cache-speed',
              'demuxer-cache-state/raw-input-rate',
              'demuxer-cache-state/fw-bytes',
              'demuxer-cache-state/ts-per-stream/video/cache-duration',
              'demuxer-cache-state/ts-per-stream/audio/cache-duration',
              'demuxer-cache-idle',
              'decoder-frame-drop-count',
              'frame-drop-count',
              'video-codec',
              'video-format',
              'width',
              'height',
              'estimated-vf-fps',
              'hwdec-current',
            ]) {
              try {
                final key = name
                    .replaceAll('demuxer-cache-state/', '')
                    .replaceAll('ts-per-stream/', '');
                values[key] = p.getProperty(name);
              } catch (_) {}
            }
            report('sample', values);
            if (i == 19 && settings['seek'] != false) {
              report('seek', {'target': 100});
              await p.seek(const Duration(seconds: 100));
            }
          }
          await relay?.close();
          relay = null;
          await p.stop();
          report('end', {});
        }
      }
      report('complete', {});
      if (mounted) {
        setState(() => status = 'Complete — results in PILI_LAB logcat');
      }
    } catch (e, stack) {
      report('fatal', {
        'type': e.runtimeType.toString(),
        'message': e.toString().replaceAll(RegExp(r'https?://\S+'), '[url]'),
        'stack': stack.toString().split('\n').take(3).join('\n'),
      });
      if (mounted) {
        setState(() => status = 'Diagnostic failed: ${e.runtimeType}');
      }
    }
  }

  @override
  void dispose() {
    cancelled = true;
    relay?.close();
    client.close(force: true);
    player?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: Column(
        children: [
          Text(status, style: const TextStyle(color: Colors.white)),
          if (video != null) Expanded(child: Video(controller: video!)),
        ],
      ),
    ),
  );
}
