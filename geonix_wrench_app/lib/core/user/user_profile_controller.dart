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
  bool _loadFailed = false;

  UserProfile? get profile => _profile;
  bool get isLoading => _isLoading;

  /// True only while the very first fetch is in flight. Every screen action
  /// (renaming the shop, inviting, accepting) calls [refresh]; gating the whole
  /// app on plain [isLoading] made each one tear the tree down to a spinner and
  /// build it back, which is what showed up as flickering.
  bool get isInitialLoad => _isLoading && _profile == null;

  /// A refresh failed and we have nothing cached to fall back on.
  bool get hasFailed => _loadFailed && _profile == null;

  void _onAuthChanged() {
    final signedIn = _authService.isSignedIn;
    if (signedIn && !_wasSignedIn) {
      _wasSignedIn = true;
      refresh();
    } else if (!signedIn && _wasSignedIn) {
      _wasSignedIn = false;
      _profile = null;
      _loadFailed = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (!_authService.isSignedIn) return;
    _isLoading = true;
    notifyListeners();
    try {
      _profile = await _service.fetchMe();
      _loadFailed = false;
    } catch (_) {
      // Keep the last good profile. Dropping it on a transient network blip
      // bounced the user out to the retry screen mid-task.
      _loadFailed = true;
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
