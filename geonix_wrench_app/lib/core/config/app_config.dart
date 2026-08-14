/// Central, environment-driven backend configuration.
///
/// All backend communication is now HTTPS by default. The base URL can be
/// overridden per build without touching source code, e.g.:
///
///   flutter run --dart-define=API_BASE_URL=https://staging.geonixsoftware.com
///   flutter build apk --dart-define=API_BASE_URL=https://api.geonixsoftware.com
///
/// Never hard-code `http://` here. Local development that still needs a
/// plaintext loopback must be opted into explicitly with the flag above, not
/// baked into the source.
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://api.geonixsoftware.com',
);
