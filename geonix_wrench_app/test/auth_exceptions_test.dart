import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geonix_wrench_app/core/auth/auth_exceptions.dart';

AuthException map(String code, {String? message}) =>
    mapFirebaseAuthException(FirebaseAuthException(code: code, message: message));

void main() {
  group('mapFirebaseAuthException', () {
    test('maps the common credential failures', () {
      expect(map('wrong-password').message, 'Incorrect email or password.');
      expect(map('invalid-credential').message, 'Incorrect email or password.');
      expect(map('user-not-found').message, 'No account found with that email.');
      expect(map('email-already-in-use').message,
          'An account already exists with that email.');
      expect(map('weak-password').message, 'Choose a stronger password.');
    });

    test('normalises upper snake case codes from the REST layer', () {
      // Firebase sometimes surfaces raw REST codes; these previously fell
      // through to the useless generic message.
      expect(map('INVALID_LOGIN_CREDENTIALS').message,
          'Incorrect email or password.');
      expect(map('USER_NOT_FOUND').message, 'No account found with that email.');
      expect(map('EMAIL_NOT_FOUND').message, 'No account found with that email.');
      expect(map('EMAIL_EXISTS').message,
          'An account already exists with that email.');
      expect(map('INVALID_PASSWORD').message, 'Incorrect email or password.');
      expect(map('TOO_MANY_ATTEMPTS_TRY_LATER').message,
          'Too many attempts. Try again later.');
    });

    test('maps project-level misconfiguration to actionable text', () {
      expect(map('configuration-not-found').message, contains('not configured'));
      expect(map('api-key-not-valid').message, contains('invalid API key'));
      expect(map('operation-not-allowed').message,
          'This sign-in method is not enabled.');
    });

    test('keychain-error points at the provisioning profile', () {
      final msg = map('keychain-error').message;
      expect(msg, contains('Keychain unavailable'));
      // Signing + entitlements are configured now, so the remaining cause is an
      // expired profile (free Personal Team profiles last only 7 days).
      expect(msg, contains('provisioning profile'));
      expect(msg, isNot(contains('Something went wrong')));
    });

    test('unmapped codes surface the code instead of hiding it', () {
      final result = map('some-brand-new-code', message: 'Detail from server');
      // Tests run in debug mode, so the full detail is included.
      expect(result.message, contains('some-brand-new-code'));
      expect(result.message, contains('Detail from server'));
      expect(result.message, isNot('Something went wrong. Please try again.'));
    });

    test('describeUnexpectedAuthError includes the real error in debug', () {
      final msg = describeUnexpectedAuthError(
        StateError('boom'),
        'Something went wrong. Please try again.',
      );
      expect(msg, contains('Something went wrong'));
      expect(msg, contains('boom'));
    });
  });
}
