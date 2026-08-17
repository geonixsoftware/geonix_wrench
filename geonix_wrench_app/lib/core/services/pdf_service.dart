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
    this.baseUrlOverride,
    this.pdfDirectory,
  });

  final AuthService authService;

  /// Pins this service to one address, overriding [apiBaseUrl]. Injected by
  /// tests; left null in the app so the resolved value below is used.
  final String? baseUrlOverride;

  /// Resolved per call, not frozen at construction: a debug server override can
  /// change mid-session, and a service built before that would otherwise keep
  /// talking to the old address.
  String get baseUrl => baseUrlOverride ?? apiBaseUrl();

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
  /// With no folder chosen, it walks a chain of defaults and takes the first
  /// one it can actually write to: the platform's Downloads folder, then the
  /// root of the user's own storage, then the app's own container.
  ///
  /// Storage root sits above the app container deliberately. A job card the
  /// mechanic cannot find is barely saved at all, and the container is exactly
  /// where a file goes to be unfindable — no file manager lists it. The root of
  /// the phone's internal storage (or the desktop home folder) is the next
  /// place after Downloads that the user can actually browse to.
  static Future<Directory> resolveTargetDirectory(String? preferred) async {
    if (preferred != null && preferred.isNotEmpty) {
      final chosen = Directory(preferred);
      if (await _isWritable(chosen)) return chosen;
      AppLogger.warn(
        'PdfService: configured PDF folder is not writable, falling back',
      );
    }

    for (final candidate in await _defaultCandidates()) {
      if (await _isWritable(candidate)) return candidate;
    }

    // Nothing user-visible would take the write. The container always will, and
    // the share sheet is then the way the document actually leaves the app.
    return getApplicationDocumentsDirectory();
  }

  /// Every default worth trying, best first.
  ///
  /// Each one is probed rather than assumed: which of these a given device
  /// permits varies by OS version and sandbox, so the list is a preference
  /// order, not a prediction.
  static Future<List<Directory>> _defaultCandidates() async {
    if (kIsWeb) return const [];
    return [...await _downloadsCandidates(), ..._storageRootCandidates()];
  }

  /// Downloads folders to try, best first.
  ///
  /// Android has no `getDownloadsDirectory()`, so the shared folder is named
  /// directly. Whether that write lands depends on the device's storage rules —
  /// scoped storage blocks it on newer releases — which is why the app-scoped
  /// `.../files/Download` sits behind it as one that always works.
  static Future<List<Directory>> _downloadsCandidates() async {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      try {
        final downloads = await getDownloadsDirectory();
        return downloads == null ? const [] : [downloads];
      } catch (e, stackTrace) {
        AppLogger.warn(
          'PdfService: downloads folder unavailable',
          e,
          stackTrace,
        );
        return const [];
      }
    }

    if (Platform.isAndroid) {
      final candidates = [
        Directory('/storage/emulated/0/Download'),
        Directory('/sdcard/Download'),
      ];
      try {
        final external = await getExternalStorageDirectory();
        if (external != null) {
          // Created rather than probed: unlike the shared folders above, this
          // one belongs to the app and simply does not exist until asked for.
          candidates.add(
            await Directory(
              '${external.path}/Download',
            ).create(recursive: true),
          );
        }
      } catch (e, stackTrace) {
        AppLogger.warn(
          'PdfService: external storage unavailable',
          e,
          stackTrace,
        );
      }
      return candidates;
    }

    // iOS: no shared Downloads folder exists.
    return const [];
  }

  /// The top of the user's own storage — where a PDF lands when no Downloads
  /// folder will take it.
  ///
  /// "Root" here means the root the *user* sees: the top of internal storage on
  /// Android, the home folder on a desktop. Not the filesystem root, which no
  /// platform here would let an app write to anyway.
  static List<Directory> _storageRootCandidates() {
    if (Platform.isAndroid) {
      return [Directory('/storage/emulated/0'), Directory('/sdcard')];
    }

    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      return home == null || home.isEmpty ? const [] : [Directory(home)];
    }

    if (Platform.isWindows) {
      final environment = Platform.environment;
      final profile = environment['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) return [Directory(profile)];
      final drive = environment['HOMEDRIVE'];
      final path = environment['HOMEPATH'];
      if (drive != null &&
          path != null &&
          drive.isNotEmpty &&
          path.isNotEmpty) {
        return [Directory('$drive$path')];
      }
      return const [];
    }

    // iOS: everything outside the app container is off limits, so there is no
    // root to fall back to.
    return const [];
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

  Future<File> generate(JobCard card, AppCurrency currency) =>
      download(jobCardId: card.id, currency: currency);

  /// Fetches a job card's PDF and saves it, without needing the card itself.
  ///
  /// The recent-activity list keeps only a job's id, so re-downloading from it
  /// cannot go through [generate] — and does not need to: the server renders
  /// the PDF from its own stored copy either way.
  Future<File> download({
    required int jobCardId,
    required AppCurrency currency,
  }) async {
    final uri = Uri.parse('$baseUrl/api/jobcards/$jobCardId/pdf');
    final http.Response response;
    try {
      response = await withApiTimeout(
        () async => http.get(
          uri,
          headers: {
            'X-Currency': currency.code,
            ...await authHeader(authService),
          },
        ),
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
    final fileName =
        'job_card_${jobCardId}_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final file = File('${directory.path}/$fileName');
    await file.writeAsBytes(bytes);

    AppLogger.api('PdfService: wrote $fileName (${bytes.length} bytes)');

    // Retained encrypted copy in the app container, unchanged in spirit from
    // the original design: the app's own record stays protected at rest.
    try {
      final protectedBytes = await FileCipher.encryptBytes(bytes);
      final documents = await getApplicationDocumentsDirectory();
      await File(
        '${documents.path}/$fileName.enc',
      ).writeAsBytes(protectedBytes);
    } catch (e, stackTrace) {
      // The exported PDF is what the user asked for and it is already on disk;
      // losing the archived copy must not fail the save.
      AppLogger.warn(
        'PdfService: could not write encrypted archive copy',
        e,
        stackTrace,
      );
    }

    try {
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'job_card_$jobCardId.pdf',
      );
    } catch (_) {
      // Sharing is unavailable on this platform; the saved file is the result.
    }

    return file;
  }
}
