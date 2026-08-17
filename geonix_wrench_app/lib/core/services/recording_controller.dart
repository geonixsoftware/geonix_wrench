import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../utils/secure_logger.dart';

enum RecordingState { idle, recording, stopped }

class RecordingController extends ChangeNotifier {
  /// How long [stop] will wait for the platform to finish writing the file
  /// before giving up and uploading whatever is on disk. Finalisation takes
  /// milliseconds in practice; this is only a backstop.
  static const Duration _finalizeTimeout = Duration(seconds: 5);
  static const Duration _finalizePollInterval = Duration(milliseconds: 50);

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _ticker;

  /// Wall-clock source for [elapsed].
  ///
  /// The elapsed time used to be accumulated as `+= 200ms` per timer tick.
  /// [Timer.periodic] only guarantees it fires *no earlier* than the interval,
  /// so every late tick — and they are routinely late under load — silently
  /// under-reported the recording, and the drift grew with the take. It also
  /// gates the minimum-length check, so a genuinely long recording could be
  /// discarded as "too short". A stopwatch cannot drift.
  final Stopwatch _stopwatch = Stopwatch();

  RecordingState _state = RecordingState.idle;
  String? _lastRecordingPath;

  /// Elapsed time and input level change many times a second. They are exposed
  /// as listenables rather than folded into [notifyListeners] so that only the
  /// timer readout and the level meter rebuild — a plain notification here made
  /// the whole record screen (date formatting, recent-activity list and all)
  /// rebuild roughly twelve times a second, which is what made it stutter.
  final ValueNotifier<Duration> elapsedListenable = ValueNotifier(
    Duration.zero,
  );
  final ValueNotifier<double> amplitudeListenable = ValueNotifier(0);

  RecordingState get state => _state;
  Duration get elapsed => elapsedListenable.value;
  double get amplitude => amplitudeListenable.value;
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
      path = 'geonix_wrench_${DateTime.now().microsecondsSinceEpoch}.m4a';
    } else {
      final directory = await getTemporaryDirectory();
      // Reclaim any leftover temp recordings from interrupted previous sessions
      // (app killed mid-upload, crash, etc.) so they don't accumulate on disk.
      await _purgeStaleTempFiles(directory);
      path =
          '${directory.path}/geonix_wrench_${DateTime.now().microsecondsSinceEpoch}.m4a';
      File(path).createSync(recursive: true);
    }

    await _recorder.start(
      kIsWeb
          ? const RecordConfig()
          // AAC in an MP4 container, *not* `pcm16bits`. The PCM encoder does
          // not produce a self-describing file on the platforms we ship:
          //
          //   - macOS wrote a WAV whose header announced 32-bit float at the
          //     device's native rate while the samples on disk were 16-bit
          //     integer. Every decoder then read the payload as float, which
          //     yields NaNs and full-scale noise, Whisper's VAD discarded the
          //     lot as non-speech, and the server rejected the upload as
          //     containing no usable speech. The recordings were always fine —
          //     only the header describing them was wrong.
          //   - Android writes raw headerless PCM for this encoder, which
          //     leaves the server probing a file with no format information
          //     at all.
          //
          // An MP4/AAC file cannot fail this way: the container carries the
          // encoder's own description of the payload, so there is nothing to
          // disagree with. It is also roughly a tenth of the size, which
          // matters against the server's upload cap — 16-bit 48kHz PCM hit it
          // after about four minutes of dictation.
          : const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
      path: path,
    );

    elapsedListenable.value = Duration.zero;
    amplitudeListenable.value = 0;
    _stopwatch
      ..reset()
      ..start();
    _state = RecordingState.recording;
    notifyListeners();

    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      elapsedListenable.value = _stopwatch.elapsed;
    });

    _amplitudeSubscription = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 150))
        .listen((amplitude) {
          const minDb = -45.0;
          final normalized = ((amplitude.current - minDb) / (0 - minDb)).clamp(
            0.0,
            1.0,
          );
          amplitudeListenable.value = normalized;
        });
  }

  Future<String?> stop() async {
    _ticker?.cancel();
    _ticker = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    _stopwatch.stop();
    // Publish the final reading: the last periodic tick lands up to 200ms
    // before the stop, and the minimum-length check reads this value.
    elapsedListenable.value = _stopwatch.elapsed;

    String? path;
    try {
      path = await _recorder.stop();
    } catch (e, stackTrace) {
      AppLogger.error('RecordingController.stop() failed', e, stackTrace);
      amplitudeListenable.value = 0;
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
      amplitudeListenable.value = 0;
      _state = RecordingState.stopped;
      notifyListeners();
      return null;
    }

    if (!kIsWeb) await _awaitFinalized(path);

    _lastRecordingPath = path;
    amplitudeListenable.value = 0;
    _state = RecordingState.stopped;
    notifyListeners();
    return path;
  }

  /// Waits until the recorder has actually finished writing [path].
  ///
  /// macOS stops by calling `AVCaptureAudioFileOutput.stopRecording()`, which
  /// completes asynchronously, and returns the path without waiting for it —
  /// the file measurably keeps growing after `stop()` has already handed it
  /// back. Uploading straight away therefore ships a file that is still being
  /// written, and for MP4 that is fatal rather than merely truncating: the
  /// `moov` atom describing the audio stream is only appended at the very end,
  /// and without it the file decodes to nothing at all.
  ///
  /// A top-level `moov` box is exactly the "finished" signal, so this polls for
  /// one. On Android and iOS the file is already complete when `stop()` returns
  /// and the first check passes immediately.
  Future<void> _awaitFinalized(String path) async {
    final file = File(path);
    final deadline = DateTime.now().add(_finalizeTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await mp4HasMoovAtom(file)) return;
      await Future<void>.delayed(_finalizePollInterval);
    }
    // Better to attempt the upload and let it fail loudly than to sit here.
    AppLogger.warn(
      'RecordingController: recording was not finalized within '
      '${_finalizeTimeout.inSeconds}s — uploading it anyway',
    );
  }

  void reset() {
    _stopwatch
      ..stop()
      ..reset();
    elapsedListenable.value = Duration.zero;
    amplitudeListenable.value = 0;
    _state = RecordingState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _amplitudeSubscription?.cancel();
    _recorder.dispose();
    elapsedListenable.dispose();
    amplitudeListenable.dispose();
    super.dispose();
  }
}

class RecordingPermissionException implements Exception {}

/// Whether [file] contains a top-level `moov` box.
///
/// An MP4 recording is only playable once its `moov` box has been written, and
/// recorders append it last, so its presence is what marks the file finished.
/// This walks the top-level box list rather than searching the bytes, so audio
/// payload that happens to contain `moov` cannot be mistaken for the real box.
///
/// Returns false for anything it cannot parse — a partly-written file, an empty
/// one, or a container that isn't MP4 at all.
Future<bool> mp4HasMoovAtom(File file) async {
  RandomAccessFile? handle;
  try {
    handle = await file.open();
    final length = await handle.length();
    var offset = 0;
    while (offset + 8 <= length) {
      await handle.setPosition(offset);
      final header = await handle.read(8);
      if (header.length < 8) return false;
      if (String.fromCharCodes(header.sublist(4, 8)) == 'moov') return true;

      var size = ByteData.sublistView(header).getUint32(0);
      if (size == 1) {
        // Size 1 means the real 64-bit length follows the box header.
        final extended = await handle.read(8);
        if (extended.length < 8) return false;
        size = ByteData.sublistView(extended).getUint64(0);
      } else if (size == 0) {
        // Size 0 means "runs to end of file", so no box can follow it.
        return false;
      }
      // Anything smaller than the header it just read cannot be a real box,
      // and advancing by it would loop forever.
      if (size < 8) return false;
      offset += size;
    }
    return false;
  } catch (e, stackTrace) {
    AppLogger.warn(
      'mp4HasMoovAtom: could not inspect ${file.path}',
      e,
      stackTrace,
    );
    return false;
  } finally {
    await handle?.close();
  }
}

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

  /// Deletes every leftover `geonix_wrench_*` recording in the temp directory.
  /// These recordings are transient by design; anything still present when a
  /// new recording starts is an orphan that would otherwise leak disk space.
  /// The extension is deliberately not matched on, so `.wav` files left behind
  /// by builds that predate the move to `.m4a` are reclaimed too.
  Future<void> _purgeStaleTempFiles(Directory tempDir) async {
    if (kIsWeb) return;
    try {
      final entities = tempDir.list();
      await for (final entity in entities) {
        if (entity is File &&
            entity.uri.pathSegments.last.startsWith('geonix_wrench_')) {
          await entity.delete();
        }
      }
    } catch (e, stackTrace) {
      AppLogger.warn(
        'RecordingController: failed to purge stale temp files',
        e,
        stackTrace,
      );
    }
  }
}
