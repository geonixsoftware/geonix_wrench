import 'package:flutter_test/flutter_test.dart';
import 'package:geonix_wrench_app/core/utils/duration_formatter.dart';

void main() {
  group('formatLaborTime', () {
    test('renders a part hour as minutes', () {
      // The reported bug: 0.75 was shown as "0.75", read as "0.75 hours",
      // and risked being billed as 75 minutes.
      expect(formatLaborTime(0.75), '45m');
      expect(formatLaborTime(0.5), '30m');
      expect(formatLaborTime(0.25), '15m');
    });

    test('renders hours and minutes together', () {
      expect(formatLaborTime(1.75), '1h 45m');
      expect(formatLaborTime(2.5), '2h 30m');
      expect(formatLaborTime(10.25), '10h 15m');
    });

    test('drops the minutes on a whole hour', () {
      expect(formatLaborTime(1), '1h');
      expect(formatLaborTime(2), '2h');
      expect(formatLaborTime(8), '8h');
    });

    test('zero reads as zero minutes, not blank', () {
      expect(formatLaborTime(0), '0m');
    });

    test('rounds to the nearest minute', () {
      // 1/3 h = 20 min exactly; 0.3456 h = 20.7 min -> 21.
      expect(formatLaborTime(1 / 3), '20m');
      expect(formatLaborTime(0.3456), '21m');
    });

    test('rounding up to a full hour carries correctly', () {
      // 0.999 h = 59.94 min -> 60 -> "1h", never "0h 60m".
      expect(formatLaborTime(0.999), '1h');
    });

    test('negative and non-finite values degrade to zero rather than throwing', () {
      expect(formatLaborTime(-1), '0m');
      expect(formatLaborTime(double.nan), '0m');
      expect(formatLaborTime(double.infinity), '0m');
    });

    test('matches the backend pdf_generator._format_labor_time', () {
      // These pairs are the contract between this function and the printed
      // job card. If the backend formatter changes, this test must fail.
      const fromBackend = <(double, String)>[
        (0.0, '0m'),
        (0.25, '15m'),
        (0.75, '45m'),
        (1.0, '1h'),
        (1.75, '1h 45m'),
        (2.0, '2h'),
        (3.5, '3h 30m'),
      ];
      for (final (hours, expected) in fromBackend) {
        expect(formatLaborTime(hours), expected, reason: 'for $hours hours');
      }
    });
  });
}
