import 'package:flutter/foundation.dart';

/// Central, environment-driven backend configuration.
///
/// All backend communication is now HTTPS by default. The base URL can be
/// overridden per build without touching source code, e.g.:
///
///   flutter run --dart-define=API_BASE_URL=https://staging.geonixsoftware.com
///   flutter build apk --dart-define=API_BASE_URL=https://api.geonixsoftware.com
///
/// Release builds always default to HTTPS — a plaintext default must never ship.
/// Debug builds default to the loopback backend so local development works
/// without a flag. Loopback is exempt from App Transport Security and never
/// leaves the machine, so this is not the cleartext exposure the HTTPS migration
/// was guarding against.
/// Debug builds default to the loopback backend so local development works
/// without a flag. Release builds have NO default: the previous one pointed at
/// https://api.geonixsoftware.com, a host that does not resolve, so a release
/// build failed at runtime on every request with an opaque network error.
/// An empty default makes [assertApiBaseUrlConfigured] fail loudly at startup
/// instead.
const String _debugBaseUrl = 'http://127.0.0.1:8000';

const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: kDebugMode ? _debugBaseUrl : '',
);

/// True when this build actually knows where the backend is.
bool get isApiBaseUrlConfigured => kApiBaseUrl.isNotEmpty;

/// Call once at startup. Fails the build's first run rather than letting every
/// request die with a confusing connection error.
void assertApiBaseUrlConfigured() {
  if (isApiBaseUrlConfigured) return;
  throw StateError(
    'API_BASE_URL is not set. Release builds must be given the backend host:\n'
    '  flutter build <target> --dart-define=API_BASE_URL=https://your-api-host\n'
    'See RELEASE_TODO.txt.',
  );
}

/// Where Stripe sends the customer back after checkout.
///
/// Points at the published GitHub Pages site, which actually serves the
/// billing success/cancel pages. It previously defaulted to
/// https://geonixsoftware.com/... , a host that does not resolve (NXDOMAIN),
/// so a customer who had just paid landed on a dead page.
///
/// Override per build once a custom domain exists:
///
///   flutter build macos --dart-define=WEB_BASE_URL=https://yourdomain.com
const String kWebBaseUrl = String.fromEnvironment(
  'WEB_BASE_URL',
  defaultValue: 'https://geonixsoftware.github.io/geonix',
);

const String kCheckoutSuccessUrl = '$kWebBaseUrl/wrench-billing-success.html';
const String kCheckoutCancelUrl = '$kWebBaseUrl/wrench-billing-cancel.html';
