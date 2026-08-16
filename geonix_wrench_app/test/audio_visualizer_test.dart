import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geonix_wrench_app/core/theme/app_theme.dart';
import 'package:geonix_wrench_app/features/record/widgets/audio_visualizer.dart';

Widget _host({required double amplitude, required bool isActive}) {
  return MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: AudioVisualizer(amplitude: amplitude, isActive: isActive),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('paints the meter instead of building a widget per bar', (tester) async {
    await tester.pumpWidget(_host(amplitude: 0.5, isActive: true));

    // The bars used to be 32 AnimatedContainers in a Row, each restarting an
    // implicit animation on every sample. One painter replaces all of them.
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byType(AnimatedContainer), findsNothing);

    await tester.pumpWidget(_host(amplitude: 0, isActive: false));
    await tester.pumpAndSettle();
  });

  testWidgets('keeps scrolling while the level is perfectly steady', (tester) async {
    // The old meter only advanced when `amplitude` changed value, so a steady
    // input — silence above all, which clamps every sample to the floor —
    // froze it mid-scroll.
    await tester.pumpWidget(_host(amplitude: 0.4, isActive: true));

    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester.hasRunningAnimations,
        isTrue,
        reason: 'meter stalled after ${(i + 1) * 120}ms of unchanged amplitude',
      );
    }

    await tester.pumpWidget(_host(amplitude: 0, isActive: false));
    await tester.pumpAndSettle();
  });

  testWidgets('drains and stops animating once recording ends', (tester) async {
    await tester.pumpWidget(_host(amplitude: 0.9, isActive: true));
    await tester.pump(const Duration(milliseconds: 240));

    await tester.pumpWidget(_host(amplitude: 0, isActive: false));

    // Settles rather than holding the last waveform forever — and, just as
    // importantly, does not leave a ticker running on an idle screen.
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('survives a bar count change', (tester) async {
    await tester.pumpWidget(_host(amplitude: 0.3, isActive: true));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: AudioVisualizer(amplitude: 0.3, isActive: false, barCount: 8),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
