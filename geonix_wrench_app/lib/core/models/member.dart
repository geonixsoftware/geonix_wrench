class Member {
  Member({
    required this.id,
    this.handle,
    this.displayName,
    required this.orgRole,
  });

  final int id;
  final String? handle;
  final String? displayName;
  final String orgRole;

  factory Member.fromJson(Map<String, dynamic> json) {
    return Member(
      id: json['id'] as int,
      handle: json['handle'] as String?,
      displayName: json['display_name'] as String?,
      orgRole: (json['org_role'] ?? '').toString(),
    );
  }
}
