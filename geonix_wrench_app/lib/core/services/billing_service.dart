import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';
import '../models/billing_status.dart';
import 'auth_http_helper.dart';

class BillingException implements Exception {
  BillingException(this.message);
  final String message;

  @override
  String toString() => message;
}

class BillingService {
  BillingService({required this.authService, this.baseUrlOverride});

  final AuthService authService;

  /// Pins this service to one address, overriding [apiBaseUrl]. Injected by
  /// tests; left null in the app so the resolved value below is used.
  final String? baseUrlOverride;

  /// Resolved per call, not frozen at construction: a debug server override can
  /// change mid-session, and a service built before that would otherwise keep
  /// talking to the old address.
  String get baseUrl => baseUrlOverride ?? apiBaseUrl();

  String _detailFrom(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {}
    return 'Server returned ${response.statusCode}';
  }

  /// Reads the subscription status.
  ///
  /// Set [reconcile] when the answer must be authoritative rather than merely
  /// current — returning from checkout, above all. It asks the server to verify
  /// against Stripe if it has nothing active on file, which covers a webhook
  /// that was never delivered. It costs a Stripe round-trip, so the routine
  /// refresh path leaves it off.
  Future<BillingStatus> fetchStatus({bool reconcile = false}) async {
    final uri = Uri.parse(
      '$baseUrl/api/billing/status${reconcile ? '?reconcile=true' : ''}',
    );
    http.Response response;
    try {
      response = await withApiTimeout(
        () async => http.get(uri, headers: await authHeader(authService)),
      );
    } catch (e) {
      throw BillingException('Could not reach the processing server');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BillingException(_detailFrom(response));
    }
    return BillingStatus.fromJson(
      (jsonDecode(response.body) as Map).cast<String, dynamic>(),
    );
  }

  Future<String> createCheckoutSession({
    required String plan,
    int? quantity,
    required String successUrl,
    required String cancelUrl,
  }) async {
    final uri = Uri.parse('$baseUrl/api/billing/checkout-session');
    http.Response response;
    try {
      response = await withApiTimeout(
        () async => http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            ...await authHeader(authService),
          },
          body: jsonEncode({
            'plan': plan,
            'quantity': ?quantity,
            'success_url': successUrl,
            'cancel_url': cancelUrl,
          }),
        ),
      );
    } catch (e) {
      throw BillingException('Could not reach the processing server');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BillingException(_detailFrom(response));
    }
    final decoded = (jsonDecode(response.body) as Map).cast<String, dynamic>();
    return decoded['checkout_url'].toString();
  }

  /// Opens the Stripe Billing Portal, where a customer can cancel, change
  /// their card or download invoices. None of that existed in-app before.
  Future<String> createPortalSession({required String returnUrl}) async {
    final uri = Uri.parse('$baseUrl/api/billing/portal-session');
    http.Response response;
    try {
      response = await withApiTimeout(
        () async => http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            ...await authHeader(authService),
          },
          body: jsonEncode({'return_url': returnUrl}),
        ),
      );
    } catch (e) {
      throw BillingException('Could not reach the processing server');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BillingException(_detailFrom(response));
    }
    final decoded = (jsonDecode(response.body) as Map).cast<String, dynamic>();
    return decoded['portal_url'].toString();
  }

  /// Changes the seat count on an existing Team subscription. Returns the
  /// refreshed status so the caller does not need a second round trip.
  Future<BillingStatus> updateSeats(int quantity) async {
    final uri = Uri.parse('$baseUrl/api/billing/seats');
    http.Response response;
    try {
      response = await withApiTimeout(
        () async => http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            ...await authHeader(authService),
          },
          body: jsonEncode({'quantity': quantity}),
        ),
      );
    } catch (e) {
      throw BillingException('Could not reach the processing server');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BillingException(_detailFrom(response));
    }
    return BillingStatus.fromJson(
      (jsonDecode(response.body) as Map).cast<String, dynamic>(),
    );
  }
}
