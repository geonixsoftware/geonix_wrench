import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

class AuthService extends ChangeNotifier {
  AuthService({FirebaseAuth? firebaseAuth, GoogleSignIn? googleSignIn})
      : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance,
        _googleSignIn = googleSignIn ?? GoogleSignIn() {
    _firebaseAuth.authStateChanges().listen((user) {
      _loaded = true;
      notifyListeners();
    });
  }

  final FirebaseAuth _firebaseAuth;
  final GoogleSignIn _googleSignIn;
  bool _loaded = false;

  User? get firebaseUser => _firebaseAuth.currentUser;
  bool get isSignedIn => firebaseUser != null;
  bool get isLoaded => _loaded;

  Future<void> signUpWithEmail(String email, String password) async {
    await _firebaseAuth.createUserWithEmailAndPassword(email: email, password: password);
  }

  Future<void> signInWithEmail(String email, String password) async {
    await _firebaseAuth.signInWithEmailAndPassword(email: email, password: password);
  }

  Future<void> signInWithGoogle() async {
    final account = await _googleSignIn.signIn();
    if (account == null) {
      throw FirebaseAuthException(code: 'canceled', message: 'Sign-in was cancelled');
    }
    final authentication = await account.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: authentication.accessToken,
      idToken: authentication.idToken,
    );
    await _firebaseAuth.signInWithCredential(credential);
  }

  Future<void> signInWithApple() async {
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
    );
    if (appleCredential.identityToken == null) {
      throw FirebaseAuthException(
        code: 'apple-sign-in-failed',
        message: 'Could not complete Sign in with Apple — no identity token was returned',
      );
    }
    final credential = OAuthProvider('apple.com').credential(
      idToken: appleCredential.identityToken,
      accessToken: appleCredential.authorizationCode,
    );
    await _firebaseAuth.signInWithCredential(credential);
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _firebaseAuth.signOut();
  }

  Future<void> sendPasswordReset(String email) async {
    await _firebaseAuth.sendPasswordResetEmail(email: email);
  }

  Future<String?> getIdToken({bool forceRefresh = false}) async {
    return firebaseUser?.getIdToken(forceRefresh);
  }
}
