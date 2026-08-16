import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../utils/secure_logger.dart';

class AuthException implements Exception {
  AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Message for an auth failure that is *not* a [FirebaseAuthException].
///
/// These previously collapsed into a bare "Something went wrong" with the real
/// cause only in a log the terminal never showed. Debug builds now surface the
/// actual error; release builds keep the friendly text.
String describeUnexpectedAuthError(Object error, String fallback) {
  AppLogger.error('Unexpected auth error', error);
  return kDebugMode ? '$fallback\n$error' : fallback;
}

AuthException mapFirebaseAuthException(FirebaseAuthException e) {
  // Firebase normalises most codes to lower-kebab, but a few surface raw from
  // the REST layer in upper snake case — accept both so real errors never fall
  // through to the unhelpful generic message.
  switch (e.code.toLowerCase().replaceAll('_', '-')) {
    case 'invalid-email':
      return AuthException('That email address looks invalid.');
    case 'user-disabled':
      return AuthException('This account has been disabled.');
    case 'user-not-found':
    case 'email-not-found':
      return AuthException('No account found with that email.');
    case 'wrong-password':
    case 'invalid-password':
    case 'invalid-credential':
    case 'invalid-login-credentials':
      return AuthException('Incorrect email or password.');
    case 'missing-password':
      return AuthException('Enter your password.');
    case 'missing-email':
      return AuthException('Enter your email.');
    case 'invalid-api-key':
    case 'api-key-not-valid':
    case 'api-key-not-valid.-please-pass-a-valid-api-key.':
      return AuthException('This app is misconfigured (invalid API key). Contact support.');
    case 'configuration-not-found':
      return AuthException('Sign-in is not configured for this app yet. Contact support.');
    case 'admin-restricted-operation':
      return AuthException('Sign-ups are currently restricted for this project.');
    case 'quota-exceeded':
      return AuthException('The service is temporarily over quota. Try again later.');
    case 'user-token-expired':
      return AuthException('Your session expired. Please sign in again.');
    case 'internal-error':
      return AuthException('The sign-in service had an internal error. Try again.');
    case 'keychain-error':
      // FirebaseAuth persists the session to Apple's *data-protection* keychain
      // (kSecUseDataProtectionKeychain = true, hardcoded in AuthKeychainServices).
      // That keychain derives its permitted access groups from a Team-ID-validated
      // signature, so an ad-hoc signed macOS build gets an empty group set and
      // every write returns errSecMissingEntitlement (-34018).
      //
      // Verified empirically: it needs BOTH a Development Team AND the
      // `keychain-access-groups` entitlement, because declaring that entitlement
      // is what makes Xcode embed a provisioning profile to authorize it. A team
      // alone still returns errSecMissingEntitlement (-34018); the entitlement
      // without a profile gets the app SIGKILLed by AMFI at launch.
      //
      // Both are configured in macos/Runner/*.entitlements. If this fires again,
      // the most likely cause is an EXPIRED profile: free "Personal Team"
      // profiles live only 7 days. Rebuild through Xcode to refresh it.
      if (kDebugMode) {
        return AuthException(
          'Keychain unavailable — the provisioning profile is likely missing or expired. '
          'Free Apple ID profiles last only 7 days; rebuild via Xcode to refresh it.',
        );
      }
      return AuthException('Could not securely save your sign-in. Please try again.');
    case 'email-already-in-use':
    case 'email-exists':
      return AuthException('An account already exists with that email.');
    case 'weak-password':
      return AuthException('Choose a stronger password.');
    case 'operation-not-allowed':
      return AuthException('This sign-in method is not enabled.');
    case 'network-request-failed':
      return AuthException('Could not reach the server. Check your connection.');
    case 'too-many-requests':
    case 'too-many-attempts-try-later':
      return AuthException('Too many attempts. Try again later.');
    case 'account-exists-with-different-credential':
      return AuthException('An account already exists with a different sign-in method.');
    case 'requires-recent-login':
      return AuthException('Please sign in again to continue.');
    case 'popup-closed-by-user':
    case 'canceled':
      return AuthException('Sign-in was cancelled.');
    default:
      // Anything still unrecognised: log it, and surface the code to the user
      // instead of a bare "Something went wrong" — a message nobody can act on
      // and which hid the real cause. The code is safe to show (it is a public
      // Firebase identifier, not user data); the fuller message is debug-only.
      AppLogger.error('Unmapped FirebaseAuthException [${e.code}]: ${e.message}');
      if (kDebugMode) {
        return AuthException('Sign-in failed [${e.code}]: ${e.message ?? 'no details'}');
      }
      return AuthException('Something went wrong (${e.code}). Please try again.');
  }
}
