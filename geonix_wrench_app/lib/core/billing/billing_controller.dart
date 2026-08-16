import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../models/billing_status.dart';
import '../services/billing_service.dart';
import '../user/user_profile_controller.dart';

class BillingController extends ChangeNotifier {
  BillingController({
    required this._authService,
    required this._profileController,
    required this._service,
  }) {
    _authService.addListener(_onChanged);
    _profileController.addListener(_onChanged);
    _onChanged();
  }

  final AuthService _authService;
  final UserProfileController _profileController;
  final BillingService _service;

  BillingStatus? _status;
  bool _isLoading = false;
  bool _resolved = false;
  String? _syncedFor;

  BillingStatus? get status => _status;
  bool get isLoading => _isLoading;

  /// Sticky across revalidation. This used to be `!_isLoading && ...`, so every
  /// background refresh briefly reported "not subscribed" and the record and
  /// settings screens flashed their locked state before flipping back.
  bool get isActive => _status?.isActive ?? false;

  /// True once a status fetch has completed at least once. Screens use this to
  /// avoid rendering "subscribe to unlock" before the answer is known.
  bool get isResolved => _resolved;

  /// Only show the locked treatment once we actually know the subscription is
  /// inactive — never during the first load.
  bool get isLocked => _resolved && !isActive;

  /// Blocking a full-screen spinner is only right when there is nothing to show.
  bool get isInitialLoad => _isLoading && _status == null;

  void _onChanged() {
    if (!_authService.isSignedIn) {
      _syncedFor = null;
      if (_status != null || _isLoading || _resolved) {
        _status = null;
        _isLoading = false;
        _resolved = false;
        notifyListeners();
      }
      return;
    }

    // Both the auth service and the profile controller notify on every change,
    // and a single profile refresh notifies twice (loading on, loading off).
    // Refetching billing each time meant duplicate requests and extra rebuilds,
    // so only resync when something that actually changes billing has moved.
    final key = '${_authService.currentUserId}:${_profileController.profile?.orgId}';
    if (key == _syncedFor) return;
    _syncedFor = key;
    // Reconcile on the first read for this user/org — once per sign-in or org
    // change, not per refresh. A subscription bought while the webhook was
    // undeliverable would otherwise stay invisible across full restarts, which
    // is exactly how it looks to a customer who has just paid. The server skips
    // the Stripe call when it already sees an active subscription, so this
    // costs nothing for subscribed users.
    refresh(reconcile: true);
  }

  /// [reconcile] asks the server to verify against Stripe when it has nothing
  /// active on file — use it after checkout, where a missing webhook would
  /// otherwise leave a paying customer locked out indefinitely.
  Future<void> refresh({bool reconcile = false}) async {
    if (!_authService.isSignedIn) {
      _status = null;
      _isLoading = false;
      _resolved = false;
      notifyListeners();
      return;
    }
    _isLoading = true;
    notifyListeners();
    try {
      _status = await _service.fetchStatus(reconcile: reconcile);
    } catch (_) {
      // Keep the previous status rather than blanking it — a dropped request
      // must not read as "subscription cancelled" and lock the user out.
    } finally {
      _isLoading = false;
      _resolved = true;
      notifyListeners();
    }
  }

  /// Changes the Team seat count. Routed through the controller rather than the
  /// screen's own service instance so every listener (billing gate, org screen)
  /// sees the new seat limit without waiting for the next refresh.
  ///
  /// Errors are rethrown for the caller to surface; unlike [refresh] a failed
  /// seat change must not silently blank the status the user is looking at.
  Future<void> updateSeats(int quantity) async {
    _status = await _service.updateSeats(quantity);
    notifyListeners();
  }

  @override
  void dispose() {
    _authService.removeListener(_onChanged);
    _profileController.removeListener(_onChanged);
    super.dispose();
  }
}
