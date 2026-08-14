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
  JobCardUpdateService({required this.authService, this.baseUrl = kApiBaseUrl});

  final AuthService authService;
  final String baseUrl;

  Future<void> update(JobCard card) async {
    final uri = Uri.parse('$baseUrl/api/jobcards/${card.id}');
    final http.Response response;
    try {
      response = await http.patch(
        uri,
        headers: {'Content-Type': 'application/json', ...await authHeader(authService)},
        body: jsonEncode({
          'labor_rate': card.laborRate,
          'parts_used': card.partsUsed.map((part) => part.toJson()).toList(),
        }),
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
