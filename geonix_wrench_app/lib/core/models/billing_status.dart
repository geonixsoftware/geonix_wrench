class BillingStatus {
  BillingStatus({
    required this.scopeType,
    this.status,
    required this.isActive,
    this.currentPeriodEnd,
    this.seatLimit,
    this.seatUsed,
  });

  final String scopeType;
  final String? status;
  final bool isActive;
  final String? currentPeriodEnd;
  final int? seatLimit;
  final int? seatUsed;

  bool get isOrgScope => scopeType == 'org';

  factory BillingStatus.fromJson(Map<String, dynamic> json) {
    return BillingStatus(
      scopeType: (json['scope_type'] ?? '').toString(),
      status: json['status'] as String?,
      isActive: json['is_active'] as bool? ?? false,
      currentPeriodEnd: json['current_period_end'] as String?,
      seatLimit: _toInt(json['seat_limit']),
      seatUsed: _toInt(json['seat_used']),
    );
  }
}

int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}
