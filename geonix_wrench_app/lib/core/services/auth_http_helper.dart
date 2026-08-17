import 'dart:async';

import '../auth/auth_service.dart';
import '../config/app_config.dart';

Future<Map<String, String>> authHeader(AuthService authService) async {
  return {'Authorization': 'Bearer ${await authService.getIdToken()}'};
}

/// Bounds a whole backend call at [kApiTimeout].
///
/// Takes a callback rather than a future so the timer covers everything the
/// call does, including the `authHeader` token refresh that runs before the
/// request is even sent — that is a network round trip to Firebase and can hang
/// on the same broken connection the request would.
///
/// Throws [TimeoutException]. Every caller already wraps its request in a
/// try/catch that reports the server as unreachable, which is exactly what a
/// timeout means here, so no call site needs to name it specially.
Future<T> withApiTimeout<T>(Future<T> Function() send, {Duration? timeout}) {
  return send().timeout(timeout ?? kApiTimeout);
}
