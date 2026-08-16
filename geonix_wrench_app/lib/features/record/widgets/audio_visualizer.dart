import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Rolling level meter for the mic input.
///
/// Drawn by a single [CustomPainter] behind a [RepaintBoundary]. The previous
/// version built one [AnimatedContainer] per bar inside a [Row]: because the
/// history shifts by one slot per sample, every bar received a new target on
/// every sample, so all 32 restarted a 140ms implicit animation ~7 times a
/// second. That meant 32 animation controllers ticking continuously, each one
/// dirtying layout for the whole row — the main source of the recording
/// screen's stutter. Painting is layout-free and costs one draw call per bar.
///
/// The meter also owns its own scroll cadence. It used to advance only when
/// `amplitude` changed value, so a steady input — silence especially, which
/// clamps every sample to the floor — reported the same number twice and froze
/// the meter mid-scroll.
class AudioVisualizer extends StatefulWidget {
  const AudioVisualizer({
    super.key,
    required this.amplitude,
    required this.isActive,
    this.barCount = 32,
    this.height = 56,
  });

  final double amplitude;
  final bool isActive;
  final int barCount;
  final double height;

  @override
  State<AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<AudioVisualizer>
    with SingleTickerProviderStateMixin {
  static const double _floor = 0.06;

  /// One bar's worth of travel. Each cycle eases the meter from [_from] to
  /// [_to]; on completion a fresh sample is appended and the cycle restarts.
  static const Duration _frame = Duration(milliseconds: 120);

  late final AnimationController _controller;
  late List<double> _from;
  late List<double> _to;

  @override
  void initState() {
    super.initState();
    _from = List<double>.filled(widget.barCount, _floor);
    _to = List<double>.filled(widget.barCount, _floor);
    _controller = AnimationController(vsync: this, duration: _frame, value: 1)
      ..addStatusListener(_onFrameComplete);
    if (widget.isActive) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(AudioVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.barCount != oldWidget.barCount) {
      _from = _resized(_from, widget.barCount);
      _to = _resized(_to, widget.barCount);
    }

    // Resume scrolling when recording starts again. While active the status
    // listener keeps the cycle going on its own.
    if (widget.isActive && !_controller.isAnimating) {
      _controller.forward(from: 0);
    }
  }

  static List<double> _resized(List<double> levels, int length) {
    if (levels.length >= length) {
      return levels.sublist(levels.length - length);
    }
    return [...List<double>.filled(length - levels.length, _floor), ...levels];
  }

  void _onFrameComplete(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;

    // At t == 1 the painted values are exactly `_to`, so that becomes the
    // origin of the next cycle.
    _from = _to;
    _to = [
      ..._to.skip(1),
      widget.isActive ? widget.amplitude.clamp(_floor, 1.0) : _floor,
    ];

    // Keep going while recording, and afterwards until the tail has drained
    // off the end — otherwise the meter would freeze holding the last waveform.
    final settled = !_to.any((level) => level > _floor + 0.001);
    if (widget.isActive || !settled) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onFrameComplete);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = widget.isActive ? p.accent : p.inkTertiary.withValues(alpha: 0.35);

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      // Isolates the meter's per-frame repaint from the rest of the card.
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _MeterPainter(
              from: _from,
              to: _to,
              t: Curves.easeOut.transform(_controller.value),
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter({
    required this.from,
    required this.to,
    required this.t,
    required this.color,
  });

  final List<double> from;
  final List<double> to;
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final count = to.length;
    if (count == 0 || size.width <= 0) return;

    // Split the available width evenly so the meter fills its container at any
    // size, rather than assuming a fixed bar width that overflowed on phones.
    final slot = size.width / count;
    final barWidth = (slot * 0.55).clamp(2.0, 5.0);
    final paint = Paint()..color = color;
    final radius = Radius.circular(barWidth / 2);

    for (var i = 0; i < count; i++) {
      final level = from[i] + (to[i] - from[i]) * t;
      final barHeight = (size.height * level).clamp(3.0, size.height);
      final left = slot * i + (slot - barWidth) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, (size.height - barHeight) / 2, barWidth, barHeight),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MeterPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.color != color ||
      !identical(oldDelegate.to, to) ||
      !identical(oldDelegate.from, from);
}
