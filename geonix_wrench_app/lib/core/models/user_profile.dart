class UserProfile {
  UserProfile({
    required this.id,
    required this.email,
    this.handle,
    this.displayName,
    this.orgId,
    this.orgRole,
    this.subscriptionStatus,
    this.currentPeriodEnd,
  });

  final int id;
  final String email;
  final String? handle;
  final String? displayName;
  final int? orgId;
  final String? orgRole;
  final String? subscriptionStatus;
  final String? currentPeriodEnd;

  bool get hasOrganization => orgId != null;
  bool get isOwner => orgRole == 'owner';
  bool get isSubscriptionActive =>
      subscriptionStatus == 'active' || subscriptionStatus == 'trialing';

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as int,
      email: (json['email'] ?? '').toString(),
      handle: json['handle'] as String?,
      displayName: json['display_name'] as String?,
      orgId: json['org_id'] as int?,
      orgRole: json['org_role'] as String?,
      subscriptionStatus: json['subscription_status'] as String?,
      currentPeriodEnd: json['current_period_end'] as String?,
    );
  }
}
