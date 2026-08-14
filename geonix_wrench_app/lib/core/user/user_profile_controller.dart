import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../models/user_profile.dart';
import '../services/user_profile_service.dart';

class UserProfileController extends ChangeNotifier {
  UserProfileController({required this._authService, required this._service}) {
    _authService.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  final AuthService _authService;
  final UserProfileService _service;

  UserProfile? _profile;
  bool _isLoading = false;
  bool _wasSignedIn = false;

  UserProfile? get profile => _profile;
  bool get isLoading => _isLoading;

  void _onAuthChanged() {
    final signedIn = _authService.isSignedIn;
    if (signedIn && !_wasSignedIn) {
      _wasSignedIn = true;
      refresh();
    } else if (!signedIn && _wasSignedIn) {
      _wasSignedIn = false;
      _profile = null;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (!_authService.isSignedIn) return;
    _isLoading = true;
    notifyListeners();
    try {
      _profile = await _service.fetchMe();
    } catch (_) {
      _profile = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _authService.removeListener(_onAuthChanged);
    super.dispose();
  }
}
