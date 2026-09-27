import 'package:material_ui/material_ui.dart';

/// Only the buttons receive touches; the rest of the video remains seekable.
class CenterPlaybackControls extends StatelessWidget {
  const CenterPlaybackControls({
    super.key,
    required this.isPlaying,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
  });

  final bool isPlaying;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    Widget button(
      String label,
      IconData icon,
      VoidCallback onTap,
      double size,
    ) {
      return Semantics(
        label: label,
        button: true,
        onTap: onTap,
        child: Tooltip(
          message: label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            // A double tap must not toggle playback or change episodes.
            onDoubleTap: () {},
            excludeFromSemantics: true,
            child: Container(
              width: size,
              height: size,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0x66000000),
              ),
              child: Icon(icon, color: Colors.white, size: size * 0.65),
            ),
          ),
        ),
      );
    }

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 24,
        children: [
          button('上一集', Icons.skip_previous, onPrevious, 48),
          button(
            isPlaying ? '暂停' : '播放',
            isPlaying ? Icons.pause : Icons.play_arrow,
            onPlayPause,
            60,
          ),
          button('下一集', Icons.skip_next, onNext, 48),
        ],
      ),
    );
  }
}
