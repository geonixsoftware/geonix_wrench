import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:geonix_wrench_app/core/config/app_config.dart';
import 'package:geonix_wrench_app/core/services/auth_http_helper.dart';

/// Why this exists: an unreachable backend does not reliably fail fast. A
/// dropped SYN leaves the socket waiting with nothing to report, and Dart's
/// HttpClient sets no connection timeout, so `AuthGate` used to sit on its
/// spinner forever rather than reaching the "Can't reach Geonix Wrench" screen
/// that was already written for the case.
///
/// These cover the helper every backend call now goes through. They do not
/// exercise a real socket — [UserProfileService] needs a Firebase-backed
/// AuthService for its token — so the guarantee pinned here is the bound
/// itself.
void main() {
  const short = Duration(milliseconds: 60);

  test('a call that never completes gives up instead of hanging', () async {
    // The exact shape of the bug: a future that simply never settles.
    await expectLater(
      withApiTimeout(() => Completer<String>().future, timeout: short),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('gives up close to the budget, not long after it', () async {
    final watch = Stopwatch()..start();
    try {
      await withApiTimeout(() => Completer<void>().future, timeout: short);
    } on TimeoutException {
      // expected
    }
    watch.stop();
    expect(watch.elapsed, lessThan(short * 10));
  });

  test('a call that answers in time passes its value straight through', () async {
    final result = await withApiTimeout(() async => 'ok', timeout: short);
    expect(result, 'ok');
  });

  test('an error from the call is not masked by the timeout', () async {
    await expectLater(
      withApiTimeout(() async => throw StateError('boom'), timeout: short),
      throwsA(isA<StateError>()),
    );
  });

  test('the clock covers work done before the request is sent', () async {
    // The reason this takes a callback rather than a future: `authHeader` awaits
    // a Firebase token refresh *before* the request goes out. That is its own
    // network round trip and hangs on the same broken connection, so a bound
    // applied only to the request itself would miss it.
    var requestSent = false;
    await expectLater(
      withApiTimeout(() async {
        await Completer<void>().future; // stands in for the token refresh
        requestSent = true;
        return 'unreachable';
      }, timeout: short),
      throwsA(isA<TimeoutException>()),
    );
    expect(requestSent, isFalse);
  });

  test('the shipped budget is long enough for a slow shop connection', () async {
    // Tight enough that a mechanic is not left staring at a spinner, loose
    // enough that a slow café or garage connection is not cut off mid-call.
    expect(kApiTimeout, greaterThanOrEqualTo(const Duration(seconds: 10)));
    expect(kApiTimeout, lessThanOrEqualTo(const Duration(seconds: 30)));
  });
}
