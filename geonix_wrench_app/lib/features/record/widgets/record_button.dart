import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// The primary record control.
///
/// A solid disc inside a soft concentric ring — the shape the reference UIs
/// use for their one hero control. While recording, the ring breathes outward
/// once per cycle instead of the stacked translucent circles the previous
/// version drew.
class RecordButton extends StatefulWidget {
  const RecordButton({
    super.key,
    required this.isRecording,
    required this.onPressed,
    this.disabled = false,
    this.size = 132,
  });

  final bool isRecording;
  final VoidCallback onPressed;
  final bool disabled;
  final double size;

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
    if (widget.isRecording) _pulse.repeat();
  }

  @override
  void didUpdateWidget(RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording && !oldWidget.isRecording) {
      _pulse.repeat();
    } else if (!widget.isRecording && oldWidget.isRecording) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    final Color fill;
    final Color foreground;
    if (widget.disabled) {
      fill = p.surfaceSunken;
      foreground = p.inkTertiary;
    } else if (widget.isRecording) {
      fill = p.danger;
      foreground = Colors.white;
    } else {
      fill = p.accent;
      foreground = p.onAccent;
    }

    final halo = widget.size + 40;

    return SizedBox(
      width: halo,
      height: halo,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Resting ring. Present in every state so the control keeps the same
          // footprint whether or not the pulse is running.
          Container(
            width: halo,
            height: halo,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.disabled
                  ? p.surfaceMuted
                  : fill.withValues(alpha: 0.10),
            ),
          ),
          if (widget.isRecording && !widget.disabled)
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                final t = _pulse.value;
                return Container(
                  width: widget.size + (halo - widget.size) * t,
                  height: widget.size + (halo - widget.size) * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: p.danger.withValues(alpha: 0.18 * (1 - t)),
                  ),
                );
              },
            ),
          Material(
            color: fill,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              // The flag used to only tint the button while leaving it tappable.
              onTap: widget.disabled ? null : widget.onPressed,
              child: SizedBox(
                width: widget.size,
                height: widget.size,
                child: Icon(
                  widget.isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                  color: foreground,
                  size: widget.size * 0.36,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
