import 'package:flutter/foundation.dart';

/// Central backend configuration.
///
/// Three sources, in order of precedence:
///
///   1. The debug-only runtime override set in Settings ([apiBaseUrl]).
///   2. `--dart-define=API_BASE_URL=...` at build time ([kApiBaseUrl]).
///   3. The debug default below, or nothing at all in a release build.
///
///   flutter run --dart-define=API_BASE_URL=https://staging.geonixsoftware.com
///   flutter build apk --dart-define=API_BASE_URL=https://api.geonixsoftware.com
///
/// Release builds have NO default. The previous one pointed at
/// https://api.geonixsoftware.com, a host that does not resolve, so a release
/// build failed at runtime on every request with an opaque network error. An
/// empty default makes [assertApiBaseUrlConfigured] fail loudly at startup
/// instead.
///
/// The debug default is loopback, which works on desktop and on a simulator —
/// they share the machine running the backend. It does NOT work on a physical
/// phone: 127.0.0.1 there is the phone itself, so the app calls a server that
/// does not exist. For a real device, either pass the machine's LAN address at
/// build time:
///
///   ipconfig getifaddr en0                       # e.g. 172.20.10.4
///   flutter run --dart-define=API_BASE_URL=http://172.20.10.4:8000
///
/// or, far less painfully, type any address into Settings → Development server
/// on a debug build and skip the rebuild entirely.
///
/// The backend must be listening on all interfaces to be reachable at a LAN
/// address (`uvicorn main:app --host 0.0.0.0`), and cleartext to a private
/// address is permitted in debug builds only — see ios/Runner/Info.plist and
/// android/app/src/debug/.
const String _debugBaseUrl = 'http://127.0.0.1:8000';

const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: kDebugMode ? _debugBaseUrl : '',
);

/// Debug-only override of the backend address, held in memory and mirrored to
/// preferences by [AppSettings].
String? _runtimeBaseUrl;

/// The address every backend call should use *right now*.
///
/// A function rather than a constant because a tunnel hands out a new URL every
/// time it restarts, and a laptop's LAN address changes with the network. Having
/// to rebuild and reinstall the app for each of those is what made testing on a
/// real phone so slow.
///
/// The override is confined to debug builds by [kDebugMode], which is a
/// compile-time constant — so in a release build this collapses to
/// `return kApiBaseUrl` and no shipped app can be aimed at another server,
/// however the preference got set.
String apiBaseUrl() {
  if (kDebugMode) {
    final override = _runtimeBaseUrl;
    if (override != null && override.isNotEmpty) return override;
  }
  return kApiBaseUrl;
}

/// Points the app at a different backend. Debug builds only; a no-op elsewhere.
void setRuntimeApiBaseUrl(String? url) {
  if (!kDebugMode) return;
  _runtimeBaseUrl = normalizeApiBaseUrl(url);
}

/// Trims a hand-typed address into something [Uri.parse] will handle, or null
/// if it is not usable.
///
/// Typing a server address on a phone keyboard invites a trailing slash, a
/// stray space, and a missing scheme. The first two are fixed silently; a
/// missing scheme is not guessed, because http vs https is exactly the
/// distinction that matters here.
String? normalizeApiBaseUrl(String? url) {
  final trimmed = url?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final withoutTrailingSlash = trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
  final parsed = Uri.tryParse(withoutTrailingSlash);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) return null;
  if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
  return withoutTrailingSlash;
}

/// How long any single backend call may take before it is treated as
/// unreachable.
///
/// Not a nicety: an unreachable host does not always fail fast. A dropped SYN —
/// a firewall silently discarding the packet, the wrong LAN address, a VPN in
/// the way, App Transport Security refusing a cleartext request — leaves the
/// socket waiting with nothing to report, and Dart's HttpClient sets no
/// connection timeout of its own. Without this bound, `AuthGate` waits on a
/// profile fetch that never settles and the app sits on its spinner forever
/// instead of reaching the "Can't reach Geonix Wrench" screen written for
/// exactly that case.
///
/// Audio upload is the one call that legitimately runs longer (transcription
/// plus extraction) and keeps its own 180s budget.
const Duration kApiTimeout = Duration(seconds: 20);

/// True when the app actually knows where the backend is — counting a debug
/// override, so a build with no `--dart-define` can still be pointed somewhere
/// from Settings.
bool get isApiBaseUrlConfigured => apiBaseUrl().isNotEmpty;

/// Call once at startup, after preferences have loaded so a stored debug
/// override counts. Fails the run rather than letting every request die with a
/// confusing connection error.
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

/// Reachable from inside the app, not only from the website: the App Store and
/// Play both expect a privacy policy a user can open from the app itself, and
/// GDPR expects the same of anyone processing EU customers' data.
const String kPrivacyPolicyUrl = '$kWebBaseUrl/privacy.html';
const String kTermsUrl = '$kWebBaseUrl/terms.html';
