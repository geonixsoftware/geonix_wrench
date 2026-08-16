class BillingStatus {
  BillingStatus({
    required this.scopeType,
    this.status,
    required this.isActive,
    this.currentPeriodEnd,
    this.seatLimit,
    this.seatUsed,
    this.plan,
    this.minSeats,
    this.teamMinSeats,
    this.pricePerSeat,
    this.individualPrice,
    this.teamPricePerSeat,
    this.currency,
    this.canManageSeats = false,
    this.needsShop = false,
  });

  final String scopeType;
  final String? status;
  final bool isActive;
  final String? currentPeriodEnd;
  final int? seatLimit;
  final int? seatUsed;
  final String? plan;

  /// Server-defined seat floor for *this scope's* plan — 1 on Individual.
  /// The plan picker must not read it; use [teamMinSeats] there.
  final int? minSeats;

  /// The Team seat floor, quoted regardless of scope, so the Team card's
  /// stepper starts at 2 even for a user who has no shop yet.
  final int? teamMinSeats;

  /// Advertised price for *this scope's own* plan — per seat on an org, per
  /// month on a user. Ambiguous by construction, so the plan picker must not
  /// read it: use [individualPrice] / [teamPricePerSeat] instead.
  final double? pricePerSeat;

  /// Advertised Individual price per month, quoted regardless of scope.
  final double? individualPrice;

  /// Advertised Team price per seat per month, quoted regardless of scope.
  ///
  /// The plans screen shows both cards at once. It used to price both from
  /// [pricePerSeat], so a user without a shop (scope `user`, which quotes the
  /// Individual price) saw the Team card advertise the Individual figure.
  final double? teamPricePerSeat;

  /// ISO currency code the price is quoted in.
  final String? currency;

  /// True only for the owner of an active Team subscription.
  final bool canManageSeats;

  /// The Team seats are paid for but the shop has not been named yet.
  ///
  /// Seats are chosen and bought before the shop exists, so on returning from
  /// checkout the app prompts for a name. It must not ask for a seat count:
  /// [seatLimit] already holds what was purchased.
  final bool needsShop;

  bool get isOrgScope => scopeType == 'org';

  factory BillingStatus.fromJson(Map<String, dynamic> json) {
    return BillingStatus(
      scopeType: (json['scope_type'] ?? '').toString(),
      status: json['status'] as String?,
      isActive: json['is_active'] as bool? ?? false,
      currentPeriodEnd: json['current_period_end'] as String?,
      seatLimit: _toInt(json['seat_limit']),
      seatUsed: _toInt(json['seat_used']),
      plan: json['plan'] as String?,
      minSeats: _toInt(json['min_seats']),
      teamMinSeats: _toInt(json['team_min_seats']),
      pricePerSeat: _toDouble(json['price_per_seat']),
      individualPrice: _toDouble(json['individual_price']),
      teamPricePerSeat: _toDouble(json['team_price_per_seat']),
      currency: json['currency'] as String?,
      canManageSeats: json['can_manage_seats'] as bool? ?? false,
      needsShop: json['needs_shop'] as bool? ?? false,
    );
  }
}

int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

double? _toDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}
