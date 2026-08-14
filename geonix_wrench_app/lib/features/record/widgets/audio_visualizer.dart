import 'dart:collection';

import 'package:flutter/material.dart';

class AudioVisualizer extends StatefulWidget {
  const AudioVisualizer({
    super.key,
    required this.amplitude,
    required this.isActive,
    this.barCount = 32,
    this.height = 64,
  });

  final double amplitude;
  final bool isActive;
  final int barCount;
  final double height;

  @override
  State<AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<AudioVisualizer> {
  late final ListQueue<double> _levels;

  @override
  void initState() {
    super.initState();
    _levels = ListQueue<double>.from(List.filled(widget.barCount, 0.04));
  }

  @override
  void didUpdateWidget(AudioVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.amplitude != oldWidget.amplitude) {
      _levels.addLast(widget.isActive ? widget.amplitude.clamp(0.04, 1.0) : 0.04);
      if (_levels.length > widget.barCount) {
        _levels.removeFirst();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isActive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).dividerColor;

    return SizedBox(
      height: widget.height,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final level in _levels)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 4,
                height: widget.height * level,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
