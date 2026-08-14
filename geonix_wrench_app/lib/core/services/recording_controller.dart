import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../utils/secure_logger.dart';

enum RecordingState { idle, recording, stopped }

class RecordingController extends ChangeNotifier {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _ticker;

  RecordingState _state = RecordingState.idle;
  Duration _elapsed = Duration.zero;
  double _amplitude = 0;
  String? _lastRecordingPath;

  RecordingState get state => _state;
  Duration get elapsed => _elapsed;
  double get amplitude => _amplitude;
  String? get lastRecordingPath => _lastRecordingPath;
  bool get isRecording => _state == RecordingState.recording;

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    if (!await hasPermission()) {
      throw RecordingPermissionException();
    }

    // On web there's no filesystem to write to — the browser records into
    // memory and hands back a blob: URI from stop(), so `path` here is just
    // a required-but-unused placeholder for the web platform implementation.
    String path;
    if (kIsWeb) {
      path = 'geonix_wrench_${DateTime.now().microsecondsSinceEpoch}.wav';
    } else {
      final directory = await getTemporaryDirectory();
      // Reclaim any leftover temp recordings from interrupted previous sessions
      // (app killed mid-upload, crash, etc.) so they don't accumulate on disk.
      await _purgeStaleTempFiles(directory);
      path =
          '${directory.path}/geonix_wrench_${DateTime.now().microsecondsSinceEpoch}.wav';
      File(path).createSync(recursive: true);
    }

    await _recorder.start(
      kIsWeb
          ? const RecordConfig()
          : const RecordConfig(encoder: AudioEncoder.pcm16bits),
      path: path,
    );

    _elapsed = Duration.zero;
    _amplitude = 0;
    _state = RecordingState.recording;
    notifyListeners();

    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _elapsed += const Duration(milliseconds: 200);
      notifyListeners();
    });

    _amplitudeSubscription = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 150))
        .listen((amplitude) {
      const minDb = -45.0;
      final normalized =
          ((amplitude.current - minDb) / (0 - minDb)).clamp(0.0, 1.0);
      _amplitude = normalized;
      notifyListeners();
    });
  }

  Future<String?> stop() async {
    _ticker?.cancel();
    _ticker = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    String? path;
    try {
      path = await _recorder.stop();
    } catch (e, stackTrace) {
      AppLogger.error('RecordingController.stop() failed', e, stackTrace);
      _amplitude = 0;
      _state = RecordingState.stopped;
      notifyListeners();
      return null;
    }

    // On web, `path` is a browser blob: URI — dart:io's File can't (and
    // doesn't need to) check its existence.
    if (path == null || (!kIsWeb && !File(path).existsSync())) {
      AppLogger.warn(
        'RecordingController.stop() returned a missing file path: $path',
      );
      _amplitude = 0;
      _state = RecordingState.stopped;
      notifyListeners();
      return null;
    }

    _lastRecordingPath = path;
    _amplitude = 0;
    _state = RecordingState.stopped;
    notifyListeners();
    return path;
  }

  void reset() {
    _elapsed = Duration.zero;
    _amplitude = 0;
    _state = RecordingState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _amplitudeSubscription?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}

class RecordingPermissionException implements Exception {}

extension RecordingFileCleanup on RecordingController {
  Future<void> deleteRecording(String path) async {
    // Blob URIs on web aren't filesystem paths; the browser reclaims that
    // memory on its own once dereferenced.
    if (kIsWeb) return;
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Deletes every leftover `geonix_wrench_*.wav` in the temp directory.
  /// These recordings are transient by design; anything still present when a
  /// new recording starts is an orphan that would otherwise leak disk space.
  Future<void> _purgeStaleTempFiles(Directory tempDir) async {
    if (kIsWeb) return;
    try {
      final entities = tempDir.list();
      await for (final entity in entities) {
        if (entity is File && entity.path.contains('geonix_wrench_') && entity.path.endsWith('.wav')) {
          await entity.delete();
        }
      }
    } catch (e, stackTrace) {
      AppLogger.warn('RecordingController: failed to purge stale temp files', e, stackTrace);
    }
  }
}
