import 'dart:io';

import 'package:flutter/foundation.dart';
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
  PdfService({
    required this.authService,
    this.baseUrl = kApiBaseUrl,
    this.pdfDirectory,
  });

  final AuthService authService;
  final String baseUrl;

  /// Folder chosen in Settings, or null for the platform downloads folder.
  final String? pdfDirectory;

  /// Resolves where a generated PDF should be written.
  ///
  /// [preferred] is the folder chosen in Settings. It is used only if it still
  /// exists and is still writable — a path can go stale (external drive
  /// unplugged, folder deleted, macOS sandbox access not renewed after a
  /// relaunch), and silently failing to save a job card the mechanic believes
  /// is on disk is worse than quietly falling back.
  ///
  /// Falls back to the platform downloads folder, then to app documents on
  /// mobile, where there is no downloads folder and the share sheet is the
  /// real delivery mechanism anyway.
  static Future<Directory> resolveTargetDirectory(String? preferred) async {
    if (preferred != null && preferred.isNotEmpty) {
      final chosen = Directory(preferred);
      if (await _isWritable(chosen)) return chosen;
      AppLogger.warn(
        'PdfService: configured PDF folder is not writable, falling back',
      );
    }

    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null && await _isWritable(downloads)) return downloads;
      } catch (e, stackTrace) {
        AppLogger.warn('PdfService: downloads folder unavailable', e, stackTrace);
      }
    }
    return getApplicationDocumentsDirectory();
  }

  static Future<bool> _isWritable(Directory directory) async {
    try {
      if (!await directory.exists()) return false;
      // Existence is not permission — on a sandboxed macOS build the folder
      // resolves fine and the write is what fails. Prove it with a probe.
      final probe = File(
        '${directory.path}/.geonix_write_probe_'
        '${DateTime.now().microsecondsSinceEpoch}',
      );
      await probe.writeAsBytes(const [0]);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

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

    // A job card exists to be handed to a customer, printed, or emailed, so it
    // is written as a readable PDF the mechanic can actually open — in
    // Downloads by default, or the folder chosen in Settings.
    //
    // This is a deliberate reversal of the previous behaviour, which encrypted
    // the file at rest into the app container as `.pdf.enc`. That kept no
    // cleartext copy on the device, but it also meant the document was
    // unreachable outside the app. The encrypted copy below preserves the
    // at-rest protection for the app's own retained history; the exported copy
    // is the deliverable, and it is cleartext by necessity.
    final directory = await resolveTargetDirectory(pdfDirectory);
    final fileName = 'job_card_${card.id}_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final file = File('${directory.path}/$fileName');
    await file.writeAsBytes(bytes);

    AppLogger.api('PdfService: wrote $fileName (${bytes.length} bytes)');

    // Retained encrypted copy in the app container, unchanged in spirit from
    // the original design: the app's own record stays protected at rest.
    try {
      final protectedBytes = await FileCipher.encryptBytes(bytes);
      final documents = await getApplicationDocumentsDirectory();
      await File('${documents.path}/$fileName.enc').writeAsBytes(protectedBytes);
    } catch (e, stackTrace) {
      // The exported PDF is what the user asked for and it is already on disk;
      // losing the archived copy must not fail the save.
      AppLogger.warn('PdfService: could not write encrypted archive copy', e, stackTrace);
    }

    try {
      await Printing.sharePdf(bytes: bytes, filename: 'job_card_${card.id}.pdf');
    } catch (_) {
      // Sharing is unavailable on this platform; the saved file is the result.
    }

    return file;
  }
}
