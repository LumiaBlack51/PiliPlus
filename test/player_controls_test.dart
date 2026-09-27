import 'package:PiliPlus/plugin/pl_player/widgets/backward_seek.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/center_playback_controls.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/forward_seek.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  tearDown(shutdownTimerService.reset);

  testWidgets(
    'center buttons use single taps, ignore doubles, and leave sides available',
    (tester) async {
      var previous = 0;
      var pause = 0;
      var next = 0;
      var sideSeek = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 240,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTap: () => sideSeek++,
                    ),
                  ),
                  Positioned.fill(
                    child: CenterPlaybackControls(
                      isPlaying: true,
                      onPrevious: () => previous++,
                      onPlayPause: () => pause++,
                      onNext: () => next++,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      for (final label in ['上一集', '暂停', '下一集']) {
        await tester.tap(find.byTooltip(label));
        await tester.pump(const Duration(milliseconds: 350));
      }
      expect([previous, pause, next], [1, 1, 1]);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(pause, 1);
      await tester.tapAt(const Offset(25, 100));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(25, 100));
      await tester.pump(const Duration(milliseconds: 350));
      expect(sideSeek, 1);
    },
  );

  test(
    'end-of-video shutdown is active without a countdown and can be cancelled',
    () {
      shutdownTimerService.stopAfterCurrentVideo();
      expect(shutdownTimerService.isActive, isTrue);
      expect(shutdownTimerService.isWaiting, isTrue);
      expect(shutdownTimerService.deadline, isNull);
      shutdownTimerService.reset();
      expect(shutdownTimerService.isActive, isFalse);
      expect(shutdownTimerService.isWaiting, isFalse);
      expect(shutdownTimerService.deadline, isNull);
    },
  );

  for (final forward in [false, true]) {
    testWidgets(
      '${forward ? "forward" : "backward"} seeks 10 seconds and accumulates taps',
      (tester) async {
        final submitted = <Duration>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: forward
                  ? ForwardSeekIndicator(
                      duration: const Duration(seconds: 10),
                      onSubmitted: submitted.add,
                    )
                  : BackwardSeekIndicator(
                      duration: const Duration(seconds: 10),
                      onSubmitted: submitted.add,
                    ),
            ),
          ),
        );
        final label = forward ? '快进' : '快退';
        expect(find.text('${label}10秒'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 400));
        expect(submitted, [const Duration(seconds: 10)]);
        await tester.tap(find.text('${label}10秒'));
        await tester.pump();
        expect(find.text('${label}20秒'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 400));
        expect(submitted.last, const Duration(seconds: 20));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
