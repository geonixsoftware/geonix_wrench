import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';
import '../models/job_card.dart';
import '../utils/secure_logger.dart';
import 'auth_http_helper.dart';

class AudioUploadException implements Exception {
  AudioUploadException(
    this.message, {
    this.isTimeout = false,
    this.isPaymentRequired = false,
    this.isNoSpeech = false,
    this.isPermanent = false,
  });
  final String message;
  final bool isTimeout;
  final bool isPaymentRequired;
  final bool isNoSpeech;

  /// The upload failed for a reason retrying cannot change — a server
  /// misconfiguration, or a recording this server will never accept.
  final bool isPermanent;

  @override
  String toString() => message;
}

class AudioUploadService {
  AudioUploadService({
    required this.authService,
    this.endpoint = '$kApiBaseUrl/api/process-audio',
    this.timeout = const Duration(seconds: 180),
  });

  final AuthService authService;
  final String endpoint;
  // CPU-based transcription with the medium Whisper model + an LLM
  // extraction call routinely take well over the old 15s/90s budgets,
  // especially on first run while the Whisper model is still loading.
  final Duration timeout;

  Future<JobCard> uploadRecording(String filePath) async {
    final uri = Uri.parse(endpoint);
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(await authHeader(authService));

    if (kIsWeb) {
      // On web, filePath is a browser blob: URI backed by in-memory data,
      // not a filesystem path — it has to be read back via an HTTP GET
      // rather than opened with dart:io.
      final blobResponse = await http.get(Uri.parse(filePath));
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          blobResponse.bodyBytes,
          filename: 'audio.webm',
        ),
      );
    } else {
      final file = File(filePath);
      if (!await file.exists()) {
        throw AudioUploadException('Recording file not found');
      }
      request.files.add(await http.MultipartFile.fromPath('file', filePath));
    }

    final http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await request.send().timeout(timeout);
    } on TimeoutException catch (e) {
      AppLogger.warn('AudioUploadService: request to $uri timed out', e);
      throw AudioUploadException('Server took too long to respond', isTimeout: true);
    } catch (e, stackTrace) {
      AppLogger.error('AudioUploadService: request to $uri failed', e, stackTrace);
      throw AudioUploadException('Could not reach the processing server');
    }

    final response = await http.Response.fromStream(streamedResponse);
    // NOTE: the response body is intentionally NOT logged — it can contain
    // transcript / customer data and would leak into system logs.
    AppLogger.api('AudioUploadService: $uri -> ${response.statusCode} '
        '(body ${response.bodyBytes.length} bytes)');

    // Server-side feature gate: a 402 means the backend rejected the request
    // because the subscription is not active. The client never decides this.
    if (response.statusCode == 402) {
      throw AudioUploadException(
        'This feature requires an active subscription',
        isPaymentRequired: true,
      );
    }
    // 422 is the server's verdict that the recording held no usable speech.
    // That is something the user can act on (unmuted mic, speak up, record
    // again) rather than a fault to retry, so it is flagged separately. The
    // body is not read for the reason above — the status alone says enough.
    if (response.statusCode == 422) {
      throw AudioUploadException(
        'Recording did not contain enough usable speech',
        isNoSpeech: true,
      );
    }
    // The server already separates faults it may recover from (502 provider
    // hiccup, 503 busy transcription queue, 429 rate limit) from ones it never
    // will (500 a misconfigured or rejected AI account, 400 a file type it
    // won't accept, 413 a recording over the size cap). That distinction is
    // the whole reason the backend picks between 502 and 500, so it is carried
    // through here rather than flattened back into one "server error" — a
    // Retry button on a permanent fault only ever fails again.
    const permanentStatuses = {400, 413, 500};
    if (permanentStatuses.contains(response.statusCode)) {
      throw AudioUploadException(
        'Server returned ${response.statusCode}',
        isPermanent: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AudioUploadException('Server returned ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      AppLogger.warn(
        'AudioUploadService: unexpected response format from $uri '
        '(status ${response.statusCode})',
      );
      throw AudioUploadException('Unexpected response format');
    }

    return JobCard.fromJson(decoded);
  }
}
