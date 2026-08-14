class Organization {
  Organization({
    required this.id,
    required this.name,
    required this.seatLimit,
    required this.seatUsed,
    required this.ownerUserId,
    this.subscriptionStatus,
    this.currentPeriodEnd,
  });

  final int id;
  final String name;
  final int seatLimit;
  final int seatUsed;
  final int ownerUserId;
  final String? subscriptionStatus;
  final String? currentPeriodEnd;

  bool get isFull => seatUsed >= seatLimit;
  bool get isSubscriptionActive =>
      subscriptionStatus == 'active' || subscriptionStatus == 'trialing';

  factory Organization.fromJson(Map<String, dynamic> json) {
    return Organization(
      id: json['id'] as int,
      name: (json['name'] ?? '').toString(),
      seatLimit: _toInt(json['seat_limit']) ?? 0,
      seatUsed: _toInt(json['seat_used']) ?? 0,
      ownerUserId: json['owner_user_id'] as int,
      subscriptionStatus: json['subscription_status'] as String?,
      currentPeriodEnd: json['current_period_end'] as String?,
    );
  }
}

int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}
