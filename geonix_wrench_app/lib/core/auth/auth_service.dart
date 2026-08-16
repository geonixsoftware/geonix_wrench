import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class AuthService extends ChangeNotifier {
  AuthService({FirebaseAuth? firebaseAuth})
      : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance {
    _firebaseAuth.authStateChanges().listen((user) {
      _loaded = true;
      notifyListeners();
    });
  }

  final FirebaseAuth _firebaseAuth;
  bool _loaded = false;

  User? get firebaseUser => _firebaseAuth.currentUser;
  bool get isSignedIn => firebaseUser != null;
  bool get isLoaded => _loaded;

  /// Stable identity for the signed-in user. Listeners use this to tell an
  /// actual account change apart from the many no-op notifications Firebase
  /// and the profile controller emit.
  String? get currentUserId => firebaseUser?.uid;

  Future<void> signUpWithEmail(String email, String password) async {
    await _firebaseAuth.createUserWithEmailAndPassword(email: email, password: password);
  }

  Future<void> signInWithEmail(String email, String password) async {
    await _firebaseAuth.signInWithEmailAndPassword(email: email, password: password);
  }

  Future<void> signOut() async {
    await _firebaseAuth.signOut();
  }

  Future<void> sendPasswordReset(String email) async {
    await _firebaseAuth.sendPasswordResetEmail(email: email);
  }

  Future<String?> getIdToken({bool forceRefresh = false}) async {
    return firebaseUser?.getIdToken(forceRefresh);
  }
}
