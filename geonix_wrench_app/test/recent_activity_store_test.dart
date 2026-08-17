import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geonix_wrench_app/core/models/job_card.dart';
import 'package:geonix_wrench_app/core/services/recent_activity_store.dart';

JobCard _card(int id, {String vehicle = 'VW Golf', String work = 'Oil change'}) {
  return JobCard(
    id: id,
    vehicleInfo: vehicle,
    laborHours: 1,
    workPerformed: work,
    partsUsed: const [],
    unbilledItemsFlagged: const [],
    transcript: '',
  );
}

Future<RecentActivityStore> _loaded() async {
  final store = RecentActivityStore();
  await store.load();
  return store;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('keeps five jobs by default, newest first', () async {
    final store = await _loaded();
    expect(store.limit, 5);

    for (var id = 1; id <= 7; id++) {
      await store.record(_card(id, vehicle: 'Car $id'), fallbackTitle: 'Untitled');
    }

    expect(store.entries.length, 5);
    expect(store.entries.first.title, 'Car 7');
    expect(store.entries.last.title, 'Car 3');
  });

  test('survives a restart', () async {
    final first = await _loaded();
    await first.record(_card(1, vehicle: 'Ford Transit'), fallbackTitle: 'Untitled');

    // A second store over the same preferences is what a relaunch looks like:
    // this history is the device's, so it has to outlive the process.
    final second = await _loaded();
    expect(second.entries.single.title, 'Ford Transit');
    expect(second.entries.single.jobCardId, 1);
  });

  test('a job with no vehicle falls back to the supplied title', () async {
    final store = await _loaded();
    await store.record(_card(1, vehicle: '   '), fallbackTitle: 'Untitled job');
    expect(store.entries.single.title, 'Untitled job');
  });

  test('re-processing a job moves it rather than duplicating it', () async {
    final store = await _loaded();
    await store.record(_card(1, vehicle: 'Golf'), fallbackTitle: 'Untitled');
    await store.record(_card(2, vehicle: 'Transit'), fallbackTitle: 'Untitled');
    await store.record(_card(1, vehicle: 'Golf'), fallbackTitle: 'Untitled');

    expect(store.entries.length, 2);
    expect(store.entries.first.title, 'Golf');
  });

  test('raising the limit keeps more, lowering it forgets the overflow', () async {
    final store = await _loaded();
    await store.setLimit(RecentActivityStore.maxLimit);
    for (var id = 1; id <= 10; id++) {
      await store.record(_card(id, vehicle: 'Car $id'), fallbackTitle: 'Untitled');
    }
    expect(store.entries.length, 10);

    await store.setLimit(3);
    expect(store.entries.length, 3);

    // Dropped for good, not just hidden — the ceiling is retention.
    final reloaded = await _loaded();
    expect(reloaded.entries.length, 3);
    expect(reloaded.limit, 3);
  });

  test('a limit of zero records nothing and forgets what was stored', () async {
    final store = await _loaded();
    await store.record(_card(1), fallbackTitle: 'Untitled');

    await store.setLimit(0);
    expect(store.entries, isEmpty);

    await store.record(_card(2), fallbackTitle: 'Untitled');
    expect(store.entries, isEmpty);
    expect((await _loaded()).entries, isEmpty);
  });

  test('the limit is clamped to the range the picker offers', () async {
    final store = await _loaded();
    await store.setLimit(99);
    expect(store.limit, RecentActivityStore.maxLimit);
    await store.setLimit(-4);
    expect(store.limit, RecentActivityStore.minLimit);
  });

  test('remembers where a PDF was saved', () async {
    final store = await _loaded();
    await store.record(_card(1), fallbackTitle: 'Untitled');
    await store.attachPdf(1, '/tmp/job_card_1.pdf');

    expect((await _loaded()).entries.single.pdfPath, '/tmp/job_card_1.pdf');
  });

  test('attaching a PDF to an unknown job is a no-op', () async {
    final store = await _loaded();
    await store.record(_card(1), fallbackTitle: 'Untitled');
    await store.attachPdf(999, '/tmp/nope.pdf');

    expect(store.entries.single.pdfPath, isNull);
  });

  test('a corrupt stored blob degrades to an empty list, not a crash', () async {
    SharedPreferences.setMockInitialValues({
      'recent_activity.entries': 'not json at all',
    });
    expect((await _loaded()).entries, isEmpty);
  });

  test('unreadable rows are dropped and the readable ones kept', () async {
    SharedPreferences.setMockInitialValues({
      'recent_activity.entries': '['
          '{"jobcard_id":1,"title":"Golf","subtitle":"","created_at":"2026-08-16T10:00:00.000"},'
          '{"title":"missing id","created_at":"2026-08-16T10:00:00.000"},'
          '{"jobcard_id":3,"title":"bad date","created_at":"whenever"}'
          ']',
    });

    final store = await _loaded();
    expect(store.entries.length, 1);
    expect(store.entries.single.title, 'Golf');
  });
}
