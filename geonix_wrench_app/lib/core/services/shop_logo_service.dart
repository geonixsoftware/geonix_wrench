import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';
import 'auth_http_helper.dart';

class ShopLogoException implements Exception {
  ShopLogoException(this.message, {this.isPaymentRequired = false});
  final String message;
  final bool isPaymentRequired;

  @override
  String toString() => message;
}

class ShopLogoService {
  ShopLogoService({required this.authService, this.baseUrl = kApiBaseUrl});

  final AuthService authService;
  final String baseUrl;

  Future<bool> fetchStatus() async {
    final uri = Uri.parse('$baseUrl/api/shop-logo/status');
    final http.Response response;
    try {
      response = await http.get(uri, headers: await authHeader(authService));
    } catch (e) {
      throw ShopLogoException('Could not reach the processing server');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ShopLogoException('Server returned ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['has_custom_logo'] == true;
  }

  Future<Uint8List> fetchLogoBytes() async {
    final uri = Uri.parse('$baseUrl/api/shop-logo');
    final http.Response response;
    try {
      response = await http.get(uri, headers: await authHeader(authService));
    } catch (e) {
      throw ShopLogoException('Could not reach the processing server');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ShopLogoException('Server returned ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  Future<void> uploadLogo(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$baseUrl/api/shop-logo');
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(await authHeader(authService));
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    final http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await request.send();
    } catch (e) {
      throw ShopLogoException('Could not reach the processing server');
    }
    final response = await http.Response.fromStream(streamedResponse);
    // Server-side feature gate: the backend is the source of truth for whether
    // the subscription is active. A 402 means the gate rejected this request;
    // the client never authorizes it.
    if (response.statusCode == 402) {
      throw ShopLogoException(
        'This feature requires an active subscription',
        isPaymentRequired: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ShopLogoException('Server returned ${response.statusCode}');
    }
  }

  Future<void> deleteLogo() async {
    final uri = Uri.parse('$baseUrl/api/shop-logo');
    final http.Response response;
    try {
      response = await http.delete(uri, headers: await authHeader(authService));
    } catch (e) {
      throw ShopLogoException('Could not reach the processing server');
    }
    if (response.statusCode == 402) {
      throw ShopLogoException(
        'This feature requires an active subscription',
        isPaymentRequired: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ShopLogoException('Server returned ${response.statusCode}');
    }
  }
}
