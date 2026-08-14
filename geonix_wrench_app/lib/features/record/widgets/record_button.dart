import 'package:flutter/material.dart';

class RecordButton extends StatefulWidget {
  const RecordButton({
    super.key,
    required this.isRecording,
    required this.onPressed,
    this.disabled = false,
    this.size = 152,
  });

  final bool isRecording;
  final VoidCallback onPressed;
  final bool disabled;
  final double size;

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.isRecording) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording && !oldWidget.isRecording) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isRecording && oldWidget.isRecording) {
      _pulseController.stop();
      _pulseController.value = 0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = theme.colorScheme.error;
    final accent = theme.colorScheme.primary;
    final color = widget.disabled
        ? theme.colorScheme.onSurface.withValues(alpha: 0.35)
        : (widget.isRecording ? danger : accent);

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final pulse = widget.isRecording ? _pulseController.value : 0.0;
        return SizedBox(
          width: widget.size + 24,
          height: widget.size + 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (widget.isRecording)
                Container(
                  width: widget.size + (16 * pulse),
                  height: widget.size + (16 * pulse),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.06 * (1 - pulse)),
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: 0.10 * (1 - pulse))),
                  ),
                ),
              Material(
                color: color.withValues(alpha: 0.08),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: widget.onPressed,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      widget.isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                      color: color,
                      size: widget.size * 0.36,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
