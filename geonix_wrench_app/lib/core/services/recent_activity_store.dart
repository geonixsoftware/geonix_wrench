import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/job_card.dart';
import '../utils/secure_logger.dart';

/// One processed job, as remembered by the device that recorded it.
///
/// Deliberately not the whole [JobCard]: this list lives in plain
/// [SharedPreferences], so it holds only what the tile needs to render plus the
/// id needed to ask the server for the PDF again. The transcript, the parts and
/// the prices stay on the server.
@immutable
class RecentActivityEntry {
  const RecentActivityEntry({
    required this.jobCardId,
    required this.title,
    required this.subtitle,
    required this.createdAt,
    this.pdfPath,
  });

  final int jobCardId;
  final String title;
  final String subtitle;
  final DateTime createdAt;

  /// Where this job's PDF was last written, if it has been exported. Used to
  /// re-share the existing file instead of re-fetching it when it is still
  /// on disk.
  final String? pdfPath;

  RecentActivityEntry copyWith({String? pdfPath}) {
    return RecentActivityEntry(
      jobCardId: jobCardId,
      title: title,
      subtitle: subtitle,
      createdAt: createdAt,
      pdfPath: pdfPath ?? this.pdfPath,
    );
  }

  Map<String, dynamic> toJson() => {
        'jobcard_id': jobCardId,
        'title': title,
        'subtitle': subtitle,
        'created_at': createdAt.toIso8601String(),
        if (pdfPath != null) 'pdf_path': pdfPath,
      };

  static RecentActivityEntry? fromJson(Map<String, dynamic> json) {
    final id = json['jobcard_id'];
    final createdAt = DateTime.tryParse((json['created_at'] ?? '').toString());
    if (id is! int || createdAt == null) return null;
    return RecentActivityEntry(
      jobCardId: id,
      title: (json['title'] ?? '').toString(),
      subtitle: (json['subtitle'] ?? '').toString(),
      createdAt: createdAt,
      pdfPath: json['pdf_path']?.toString(),
    );
  }
}

/// The record screen's "Recent activity" list.
///
/// Held on the phone and nowhere else. There is no server-side history
/// endpoint behind this and there deliberately isn't one: a mechanic's list of
/// recent jobs is theirs, and keeping it local means it needs no account
/// lookup, no network round trip to render, and leaves nothing behind on the
/// backend when the app is uninstalled.
class RecentActivityStore extends ChangeNotifier {
  static const _entriesKey = 'recent_activity.entries';
  static const _limitKey = 'recent_activity.limit';

  /// The most entries the user is allowed to keep. The picker in Settings runs
  /// from [minLimit] (off) to this.
  static const int maxLimit = 10;
  static const int minLimit = 0;
  static const int defaultLimit = 5;

  List<RecentActivityEntry> _entries = const [];
  int _limit = defaultLimit;

  List<RecentActivityEntry> get entries => List.unmodifiable(_entries);
  int get limit => _limit;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final storedLimit = prefs.getInt(_limitKey);
    if (storedLimit != null) _limit = storedLimit.clamp(minLimit, maxLimit);

    final raw = prefs.getString(_entriesKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _entries = decoded
              .whereType<Map>()
              .map((item) => RecentActivityEntry.fromJson(item.cast<String, dynamic>()))
              .whereType<RecentActivityEntry>()
              .take(_limit)
              .toList();
        }
      } catch (e, stackTrace) {
        // A corrupt or out-of-date blob must not stop the app from starting;
        // the worst case is an empty history.
        AppLogger.warn('RecentActivityStore: could not read stored history', e, stackTrace);
      }
    }

    notifyListeners();
  }

  /// Remembers a freshly processed job, newest first.
  Future<void> record(JobCard card, {required String fallbackTitle}) async {
    if (_limit == 0) return;

    final title = card.vehicleInfo.trim().isNotEmpty ? card.vehicleInfo.trim() : fallbackTitle;
    final entry = RecentActivityEntry(
      jobCardId: card.id,
      title: title,
      subtitle: card.workPerformed.trim(),
      createdAt: DateTime.now(),
    );

    // Re-processing the same card replaces its old row rather than showing the
    // job twice.
    final next = [entry, ..._entries.where((e) => e.jobCardId != card.id)];
    await _write(next);
  }

  /// Records where this job's PDF was last saved, so the tile can re-share the
  /// file it already has.
  Future<void> attachPdf(int jobCardId, String path) async {
    var changed = false;
    final next = <RecentActivityEntry>[];
    for (final entry in _entries) {
      if (entry.jobCardId == jobCardId && entry.pdfPath != path) {
        changed = true;
        next.add(entry.copyWith(pdfPath: path));
      } else {
        next.add(entry);
      }
    }
    if (!changed) return;
    await _write(next);
  }

  /// How many jobs to keep. `0` turns the list off and forgets what is stored,
  /// which is the only honest reading of "keep none".
  Future<void> setLimit(int value) async {
    final clamped = value.clamp(minLimit, maxLimit);
    if (clamped == _limit) return;
    _limit = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_limitKey, clamped);
    await _write(_entries);
  }

  Future<void> clear() => _write(const []);

  Future<void> _write(List<RecentActivityEntry> next) async {
    _entries = next.take(_limit).toList();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (_entries.isEmpty) {
      await prefs.remove(_entriesKey);
    } else {
      await prefs.setString(
        _entriesKey,
        jsonEncode([for (final entry in _entries) entry.toJson()]),
      );
    }
  }
}
