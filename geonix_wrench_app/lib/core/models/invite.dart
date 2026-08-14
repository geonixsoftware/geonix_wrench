class Invite {
  Invite({
    required this.id,
    required this.orgId,
    required this.orgName,
    this.invitedByHandle,
    required this.status,
    required this.createdAt,
  });

  final int id;
  final int orgId;
  final String orgName;
  final String? invitedByHandle;
  final String status;
  final String createdAt;

  factory Invite.fromJson(Map<String, dynamic> json) {
    return Invite(
      id: json['id'] as int,
      orgId: json['org_id'] as int,
      orgName: (json['org_name'] ?? '').toString(),
      invitedByHandle: json['invited_by_handle'] as String?,
      status: (json['status'] ?? '').toString(),
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}
