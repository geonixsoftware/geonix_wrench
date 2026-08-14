import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../models/billing_status.dart';
import '../services/billing_service.dart';
import '../user/user_profile_controller.dart';

class BillingController extends ChangeNotifier {
  BillingController({
    required AuthService authService,
    required UserProfileController profileController,
    required BillingService service,
  })  : _authService = authService,
        _profileController = profileController,
        _service = service {
    _authService.addListener(_onChanged);
    _profileController.addListener(_onChanged);
    _onChanged();
  }

  final AuthService _authService;
  final UserProfileController _profileController;
  final BillingService _service;

  BillingStatus? _status;
  bool _isLoading = false;

  BillingStatus? get status => _status;
  bool get isLoading => _isLoading;
  bool get isActive => !_isLoading && (_status?.isActive ?? false);

  void _onChanged() {
    if (_authService.isSignedIn) {
      refresh();
    } else if (_status != null || _isLoading) {
      _status = null;
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (!_authService.isSignedIn) {
      _status = null;
      _isLoading = false;
      notifyListeners();
      return;
    }
    _isLoading = true;
    notifyListeners();
    try {
      _status = await _service.fetchStatus();
    } catch (_) {
      _status = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _authService.removeListener(_onChanged);
    _profileController.removeListener(_onChanged);
    super.dispose();
  }
}
