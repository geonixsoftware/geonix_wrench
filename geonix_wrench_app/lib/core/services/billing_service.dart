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
  BillingService({required this.authService, this.baseUrl = kApiBaseUrl});

  final AuthService authService;
  final String baseUrl;

  String _detailFrom(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {}
    return 'Server returned ${response.statusCode}';
  }

  Future<BillingStatus> fetchStatus() async {
    final uri = Uri.parse('$baseUrl/api/billing/status');
    http.Response response;
    try {
      response = await http.get(uri, headers: await authHeader(authService));
    } catch (e) {
      throw BillingException('Could not reach the processing server');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BillingException(_detailFrom(response));
    }
    return BillingStatus.fromJson((jsonDecode(response.body) as Map).cast<String, dynamic>());
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
      response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json', ...await authHeader(authService)},
        body: jsonEncode({
          'plan': plan,
          if (quantity != null) 'quantity': quantity,
          'success_url': successUrl,
          'cancel_url': cancelUrl,
        }),
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
}
