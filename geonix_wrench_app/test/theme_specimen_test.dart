// Golden output is sensitive to the Flutter version and host platform, so this
// file is tagged: `flutter test --exclude-tags golden` skips it, and
// `flutter test --update-goldens test/theme_specimen_test.dart` refreshes it.
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geonix_wrench_app/core/theme/app_theme.dart';
import 'package:geonix_wrench_app/shared/widgets/surface_card.dart';

/// Renders the design system's building blocks so the visual result can be
/// inspected (`flutter test --update-goldens`) without booting Firebase.
///
/// This is a specimen sheet, not a regression lock: it exists so changes to the
/// palette, type scale, card treatment and control styling are reviewable.
Widget _specimen(ThemeData theme, String label) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Builder(
      builder: (context) {
        final t = Theme.of(context).textTheme;
        return Scaffold(
          appBar: AppBar(title: Text(label)),
          body: SingleChildScrollView(
            padding: AppTheme.screenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Choose a plan', style: t.headlineSmall),
                const SizedBox(height: AppTheme.space2),
                Text(
                  'Both plans include everything. Pick the one that matches how you work.',
                  style: t.bodyMedium,
                ),
                const SizedBox(height: AppTheme.space6),
                SurfaceCard(
                  accented: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Team', style: t.titleLarge),
                      const SizedBox(height: AppTheme.space1),
                      Text('For shops with several mechanics.', style: t.bodyMedium),
                      const SizedBox(height: AppTheme.space5),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text('€27', style: t.displaySmall),
                          const SizedBox(width: AppTheme.space2),
                          Text('per seat / month', style: t.bodySmall),
                        ],
                      ),
                      const SizedBox(height: AppTheme.space5),
                      const SurfaceWell(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [Text('€27.00 per seat'), Text('€54.00')],
                        ),
                      ),
                      const SizedBox(height: AppTheme.space5),
                      FilledButton(onPressed: () {}, child: const Text('Subscribe')),
                      const SizedBox(height: AppTheme.space3),
                      OutlinedButton(onPressed: () {}, child: const Text('Maybe later')),
                      const SizedBox(height: AppTheme.space3),
                      FilledButton(onPressed: null, child: const Text('Disabled')),
                    ],
                  ),
                ),
                const SizedBox(height: AppTheme.space4),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Shop details', style: t.titleMedium),
                      const SizedBox(height: AppTheme.space4),
                      const TextField(
                        decoration: InputDecoration(labelText: 'Shop name'),
                      ),
                      const SizedBox(height: AppTheme.space3),
                      const TextField(
                        decoration: InputDecoration(
                          hintText: 'you@yourshop.com',
                          prefixIcon: Icon(Icons.mail_outline_rounded),
                        ),
                      ),
                      const SizedBox(height: AppTheme.space4),
                      Text('3 of 5 seats used', style: t.bodySmall),
                      const SizedBox(height: AppTheme.space2),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                        child: const LinearProgressIndicator(value: 0.6, minHeight: 6),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

void main() {
  testWidgets('light theme specimen', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_specimen(AppTheme.light, 'Subscription'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/theme_light.png'),
    );
  });

  testWidgets('dark theme specimen', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_specimen(AppTheme.dark, 'Subscription'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/theme_dark.png'),
    );
  });
}
