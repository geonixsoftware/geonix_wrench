import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import '../auth/auth_service.dart';
import '../config/app_config.dart';
import '../models/job_card.dart';
import '../security/file_cipher.dart';
import '../settings/app_settings.dart';
import '../utils/secure_logger.dart';
import 'auth_http_helper.dart';

class PdfFetchException implements Exception {
  PdfFetchException(this.message, {this.isPaymentRequired = false});
  final String message;
  final bool isPaymentRequired;

  @override
  String toString() => message;
}

class PdfService {
  PdfService({required this.authService, this.baseUrl = kApiBaseUrl});

  final AuthService authService;
  final String baseUrl;

  Future<File> generate(JobCard card, AppCurrency currency) async {
    final uri = Uri.parse('$baseUrl/api/jobcards/${card.id}/pdf');
    final http.Response response;
    try {
      response = await http.get(
        uri,
        headers: {'X-Currency': currency.code, ...await authHeader(authService)},
      );
    } catch (e) {
      throw PdfFetchException('Could not reach the processing server');
    }

    // Server-side feature gate: the backend is the source of truth for whether
    // the subscription is active. A 402 means the gate rejected this request.
    if (response.statusCode == 402) {
      throw PdfFetchException(
        'This feature requires an active subscription',
        isPaymentRequired: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PdfFetchException('Server returned ${response.statusCode}');
    }

    final bytes = response.bodyBytes;

    // Encrypt the PDF at rest BEFORE it touches disk — no cleartext copy on the
    // device. The in-memory bytes are still used for instant sharing below.
    final protectedBytes = await FileCipher.encryptBytes(bytes);

    final directory = await getApplicationDocumentsDirectory();
    final fileName = 'job_card_${card.id}_${DateTime.now().millisecondsSinceEpoch}.pdf.enc';
    final file = File('${directory.path}/$fileName');
    await file.writeAsBytes(protectedBytes);

    AppLogger.api('PdfService: saved encrypted $fileName '
        '(${protectedBytes.length} bytes)');

    try {
      await Printing.sharePdf(bytes: bytes, filename: 'job_card_${card.id}.pdf');
    } catch (_) {
      // Sharing is unavailable on this platform; the encrypted file is saved.
    }

    return file;
  }
}
