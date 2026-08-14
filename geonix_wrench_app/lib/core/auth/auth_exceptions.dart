import 'package:firebase_auth/firebase_auth.dart';

class AuthException implements Exception {
  AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

AuthException mapFirebaseAuthException(FirebaseAuthException e) {
  switch (e.code) {
    case 'invalid-email':
      return AuthException('That email address looks invalid.');
    case 'user-disabled':
      return AuthException('This account has been disabled.');
    case 'user-not-found':
      return AuthException('No account found with that email.');
    case 'wrong-password':
    case 'invalid-credential':
      return AuthException('Incorrect email or password.');
    case 'email-already-in-use':
      return AuthException('An account already exists with that email.');
    case 'weak-password':
      return AuthException('Choose a stronger password.');
    case 'operation-not-allowed':
      return AuthException('This sign-in method is not enabled.');
    case 'network-request-failed':
      return AuthException('Could not reach the server. Check your connection.');
    case 'too-many-requests':
      return AuthException('Too many attempts. Try again later.');
    case 'account-exists-with-different-credential':
      return AuthException('An account already exists with a different sign-in method.');
    case 'requires-recent-login':
      return AuthException('Please sign in again to continue.');
    case 'popup-closed-by-user':
    case 'canceled':
      return AuthException('Sign-in was cancelled.');
    default:
      return AuthException('Something went wrong. Please try again.');
  }
}
