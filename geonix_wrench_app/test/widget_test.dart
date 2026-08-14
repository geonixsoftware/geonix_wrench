import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geonix_wrench_app/app.dart';
import 'package:geonix_wrench_app/core/settings/app_settings.dart';

void main() {
  testWidgets('Splash screen shows the app tagline', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings();
    await settings.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: const GeonixWrenchApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Field service, structured.'), findsOneWidget);

    // Flush the splash screen's delayed navigation to AuthGate so no Timer is
    // left pending at test teardown. There is no real Firebase project for
    // this test to initialize, so AuthGate is expected to fail to find its
    // AuthService provider once it builds — that failure is asserted and
    // consumed here rather than left to fail the test as an unhandled error.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNotNull);
  });
}
