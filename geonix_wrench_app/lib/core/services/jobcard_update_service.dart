import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';
import '../models/job_card.dart';
import 'auth_http_helper.dart';

class JobCardUpdateException implements Exception {
  JobCardUpdateException(this.message, {this.isPaymentRequired = false});
  final String message;
  final bool isPaymentRequired;

  @override
  String toString() => message;
}

class JobCardUpdateService {
  JobCardUpdateService({required this.authService, this.baseUrlOverride});

  final AuthService authService;

  /// Pins this service to one address, overriding [apiBaseUrl]. Injected by
  /// tests; left null in the app so the resolved value below is used.
  final String? baseUrlOverride;

  /// Resolved per call, not frozen at construction: a debug server override can
  /// change mid-session, and a service built before that would otherwise keep
  /// talking to the old address.
  String get baseUrl => baseUrlOverride ?? apiBaseUrl();

  Future<void> update(JobCard card) async {
    final uri = Uri.parse('$baseUrl/api/jobcards/${card.id}');
    final http.Response response;
    try {
      response = await withApiTimeout(
        () async => http.patch(
          uri,
          headers: {
            'Content-Type': 'application/json',
            ...await authHeader(authService),
          },
          body: jsonEncode({
            'labor_rate': card.laborRate,
            'parts_used': card.partsUsed.map((part) => part.toJson()).toList(),
          }),
        ),
      );
    } catch (e) {
      throw JobCardUpdateException('Could not reach the processing server');
    }

    if (response.statusCode == 402) {
      throw JobCardUpdateException(
        'This feature requires an active subscription',
        isPaymentRequired: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw JobCardUpdateException('Server returned ${response.statusCode}');
    }
  }
}
