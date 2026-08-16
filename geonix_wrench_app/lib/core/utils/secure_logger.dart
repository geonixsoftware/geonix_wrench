import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';

/// A logging wrapper that stops sensitive data (auth tokens, passwords, API
/// credentials and response bodies) from leaking into system logs.
///
/// Replace every `debugPrint(...)` / `print(...)` call that can touch network
/// traffic, auth state or user credentials with [AppLogger]. Output is redacted
/// before it is emitted, and HTTP response bodies are never logged verbatim —
/// only the URL, status code and body length.
class AppLogger {
  const AppLogger._();

  static const String _redacted = '***REDACTED***';

  static final List<RegExp> _sensitivePatterns = <RegExp>[
    // Bearer / JWT tokens in Authorization headers.
    RegExp(r'(Bearer\s+)[A-Za-z0-9\-._~+/]+=*', caseSensitive: false),
    RegExp(r'(authorization["\s:=]+)[^\s",}\]]+', caseSensitive: false),
    RegExp(r'(password["\s:=]+)[^\s",}\]]+', caseSensitive: false),
    RegExp(r'(access[_]?token["\s:=]+)[^\s",}\]]+', caseSensitive: false),
    RegExp(r'(id[_]?token["\s:=]+)[^\s",}\]]+', caseSensitive: false),
    RegExp(r'(identity[_]?token["\s:=]+)[^\s",}\]]+', caseSensitive: false),
    RegExp(r'(authorization[_]?code["\s:=]+)[^\s",}\]]+', caseSensitive: false),
    RegExp(r'(refresh[_]?token["\s:=]+)[^\s",}\]]+', caseSensitive: false),
    RegExp(r'(client[_]?secret["\s:=]+)[^\s",}\]]+', caseSensitive: false),
    RegExp(r'(api[_-]?key["\s:=]+)[^\s",}\]]+', caseSensitive: false),
  ];

  static String _redact(String message) {
    var out = message;
    for (final pattern in _sensitivePatterns) {
      out = out.replaceAllMapped(
        pattern,
        (match) => '${match.group(1)}$_redacted',
      );
    }
    return out;
  }

  /// Diagnostic message. Silenced entirely in release builds so no sensitive
  /// data can reach production system logs.
  static void d(String message, [Object? error, StackTrace? stackTrace]) {
    if (kReleaseMode) return;
    _emit('DEBUG', _redact(message), error, stackTrace);
  }

  static void info(String message, [Object? error, StackTrace? stackTrace]) =>
      _emit('INFO', _redact(message), error, stackTrace);

  static void warn(String message, [Object? error, StackTrace? stackTrace]) =>
      _emit('WARN', _redact(message), error, stackTrace);

  /// Always logged (needed for crash reporting) but still redacted.
  static void error(String message, [Object? error, StackTrace? stackTrace]) =>
      _emit('ERROR', _redact(message), error, stackTrace);

  /// Network helper: logs the URL + status code, never the response body.
  static void api(String message) {
    if (kReleaseMode) return;
    _emit('API', _redact(message), null, null);
  }

  static void _emit(
    String level,
    String message,
    Object? error,
    StackTrace? stackTrace,
  ) {
    // The `error` object can carry unredacted details (e.g. an http exception
    // whose toString() includes the request line or a response snippet). Redact
    // it the same way as the message so no token/secret leaks via the error arg.
    final safeError = error == null ? null : _redact(error.toString());
    dev.log(
      '[$level] $message',
      error: safeError,
      stackTrace: stackTrace,
      name: 'GeonixWrench',
    );
    // `dev.log` only surfaces in DevTools / the IDE console — on desktop it does
    // not reliably reach the `flutter run` terminal, which made these
    // diagnostics effectively invisible. Mirror to debugPrint (already redacted,
    // and stripped in release) so failures are visible where people look first.
    if (!kReleaseMode) {
      debugPrint('[$level] $message${safeError == null ? '' : ' | $safeError'}');
    }
  }
}
