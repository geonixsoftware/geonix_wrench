import 'package:flutter_test/flutter_test.dart';
import 'package:geonix_wrench_app/core/models/billing_status.dart';

void main() {
  group('BillingStatus.fromJson', () {
    test('reads the seat management fields the server sends', () {
      // Keys mirror BillingStatusResponse in the backend; a typo here fails
      // silently at runtime by disabling the seat stepper.
      final status = BillingStatus.fromJson(const {
        'scope_type': 'org',
        'status': 'active',
        'is_active': true,
        'seat_limit': 5,
        'seat_used': 3,
        'plan': 'team',
        'min_seats': 2,
        'can_manage_seats': true,
      });

      expect(status.isOrgScope, isTrue);
      expect(status.seatLimit, 5);
      expect(status.seatUsed, 3);
      expect(status.plan, 'team');
      expect(status.minSeats, 2);
      expect(status.canManageSeats, isTrue);
    });

    test('defaults seat management off when the server omits it', () {
      final status = BillingStatus.fromJson(const {
        'scope_type': 'user',
        'is_active': false,
      });

      expect(status.canManageSeats, isFalse);
      expect(status.minSeats, isNull);
      expect(status.plan, isNull);
    });

    test('reads both advertised prices independently of scope', () {
      // The plans screen shows Individual and Team side by side, so it needs
      // both figures even though the caller only occupies one scope.
      final status = BillingStatus.fromJson(const {
        'scope_type': 'user',
        'is_active': false,
        'price_per_seat': 29,
        'individual_price': 29,
        'team_price_per_seat': 25,
      });

      expect(status.individualPrice, 29);
      expect(status.teamPricePerSeat, 25);
    });

    test('reads the paid-but-unnamed-shop signal and its seat count', () {
      // Team seats are bought before the shop exists. On returning from
      // checkout the app prompts for a name only — the seat count is settled.
      final status = BillingStatus.fromJson(const {
        'scope_type': 'user',
        'status': 'active',
        'is_active': true,
        'plan': 'team',
        'seat_limit': 6,
        'needs_shop': true,
        'team_min_seats': 2,
      });

      expect(status.needsShop, isTrue);
      expect(status.seatLimit, 6);
      expect(status.teamMinSeats, 2);
    });

    test('defaults needsShop off so a missing flag never prompts', () {
      final status = BillingStatus.fromJson(const {
        'scope_type': 'user',
        'is_active': true,
      });

      expect(status.needsShop, isFalse);
      expect(status.teamMinSeats, isNull);
    });

    test('leaves the plan prices null when the server omits them', () {
      final status = BillingStatus.fromJson(const {
        'scope_type': 'user',
        'is_active': false,
        'price_per_seat': 29,
      });

      expect(status.pricePerSeat, 29);
      expect(status.individualPrice, isNull);
      expect(status.teamPricePerSeat, isNull);
    });
  });
}
