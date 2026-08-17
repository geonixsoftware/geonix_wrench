import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geonix_wrench_app/core/config/app_config.dart';
import 'package:geonix_wrench_app/core/settings/app_settings.dart';

/// The backend address used to be fixed at compile time, so pointing a phone at
/// a laptop or a tunnel meant a rebuild and reinstall every time the address
/// moved — and both of those move constantly. These cover the runtime override
/// that replaced that, and the boundary that keeps it out of release builds.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setRuntimeApiBaseUrl(null);
  });

  tearDown(() => setRuntimeApiBaseUrl(null));

  group('normalizeApiBaseUrl', () {
    test('accepts a plain http and https address', () {
      expect(normalizeApiBaseUrl('http://172.20.10.4:8000'), 'http://172.20.10.4:8000');
      expect(normalizeApiBaseUrl('https://x.trycloudflare.com'), 'https://x.trycloudflare.com');
    });

    test('forgives what a phone keyboard adds', () {
      // A trailing slash would produce '//api/auth/me' once a path is appended.
      expect(normalizeApiBaseUrl('  http://10.0.0.5:8000/  '), 'http://10.0.0.5:8000');
    });

    test('refuses an address with no scheme rather than guessing one', () {
      // http vs https is the distinction that matters most here, so guessing is
      // worse than rejecting.
      expect(normalizeApiBaseUrl('172.20.10.4:8000'), isNull);
      expect(normalizeApiBaseUrl('example.com'), isNull);
    });

    test('refuses schemes that are not http', () {
      expect(normalizeApiBaseUrl('ftp://example.com'), isNull);
      expect(normalizeApiBaseUrl('javascript:alert(1)'), isNull);
    });

    test('refuses empty and hostless input', () {
      expect(normalizeApiBaseUrl(null), isNull);
      expect(normalizeApiBaseUrl('   '), isNull);
      expect(normalizeApiBaseUrl('http://'), isNull);
    });
  });

  group('apiBaseUrl', () {
    test('falls back to the compiled-in address with no override', () {
      expect(apiBaseUrl(), kApiBaseUrl);
    });

    test('an override wins over the compiled-in address', () {
      setRuntimeApiBaseUrl('https://tunnel.example.com');
      // Skipped on a release build, where the override is inert by design.
      expect(apiBaseUrl(), kDebugMode ? 'https://tunnel.example.com' : kApiBaseUrl);
    });

    test('clearing the override restores the compiled-in address', () {
      setRuntimeApiBaseUrl('https://tunnel.example.com');
      setRuntimeApiBaseUrl(null);
      expect(apiBaseUrl(), kApiBaseUrl);
    });

    test('an unusable override is not stored', () {
      setRuntimeApiBaseUrl('not a url');
      expect(apiBaseUrl(), kApiBaseUrl);
    });
  });

  group('AppSettings', () {
    test('stores a valid address and reports it as effective', () async {
      final settings = AppSettings();
      await settings.load();

      expect(await settings.setApiBaseUrlOverride('http://192.168.1.50:8000/'), isTrue);
      expect(settings.apiBaseUrlOverride, 'http://192.168.1.50:8000');
      if (kDebugMode) {
        expect(settings.effectiveApiBaseUrl, 'http://192.168.1.50:8000');
      }
    });

    test('rejects junk and leaves the previous address alone', () async {
      final settings = AppSettings();
      await settings.load();
      await settings.setApiBaseUrlOverride('https://good.example.com');

      expect(await settings.setApiBaseUrlOverride('nonsense'), isFalse);
      expect(settings.apiBaseUrlOverride, 'https://good.example.com');
    });

    test('survives a restart, so the phone keeps talking to the same server', () async {
      final first = AppSettings();
      await first.load();
      await first.setApiBaseUrlOverride('https://tunnel.example.com');

      final second = AppSettings();
      await second.load();
      expect(second.apiBaseUrlOverride, 'https://tunnel.example.com');
      if (kDebugMode) {
        expect(apiBaseUrl(), 'https://tunnel.example.com');
      }
    });

    test('an empty string clears it rather than being rejected', () async {
      final settings = AppSettings();
      await settings.load();
      await settings.setApiBaseUrlOverride('https://tunnel.example.com');

      expect(await settings.setApiBaseUrlOverride(''), isTrue);
      expect(settings.apiBaseUrlOverride, isNull);
      expect(settings.effectiveApiBaseUrl, kApiBaseUrl);
    });
  });

  // The services resolve `baseUrl` through apiBaseUrl() on every call rather
  // than capturing it in the constructor — the bug being guarded is that they
  // are each built once when their screen first appears, so a captured address
  // would keep being used for the rest of the session after a server change.
  //
  // That is asserted here at the apiBaseUrl() level rather than on a service
  // instance: every service requires an AuthService, whose constructor reaches
  // for FirebaseAuth.instance and throws without a live Firebase app. Faking
  // Firebase to read a string getter would cost more than it proves.
  test('the value a service reads changes without rebuilding the service', () {
    String readAsAServiceWould() => apiBaseUrl();

    final before = readAsAServiceWould();
    setRuntimeApiBaseUrl('https://after.example.com');
    expect(
      readAsAServiceWould(),
      kDebugMode ? 'https://after.example.com' : before,
    );
  });
}
