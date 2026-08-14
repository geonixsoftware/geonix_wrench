import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_service.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/models/invite.dart';
import '../../core/models/member.dart';
import '../../core/models/organization.dart';
import '../../core/services/user_profile_service.dart';
import '../../core/user/user_profile_controller.dart';
import '../../shared/widgets/surface_card.dart';

class OrganizationScreen extends StatefulWidget {
  const OrganizationScreen({super.key});

  @override
  State<OrganizationScreen> createState() => _OrganizationScreenState();
}

class _OrganizationScreenState extends State<OrganizationScreen> {
  late final UserProfileService _service;
  bool _loading = true;
  bool _busy = false;
  Organization? _org;
  List<Member> _members = [];
  List<Invite> _ownerInvites = [];
  List<Invite> _myInvites = [];

  final _createNameController = TextEditingController();
  int _createSeatLimit = 5;
  final _inviteHandleController = TextEditingController();
  final Set<int> _respondingInviteIds = {};

  @override
  void initState() {
    super.initState();
    _service = UserProfileService(authService: context.read<AuthService>());
    _load();
  }

  @override
  void dispose() {
    _createNameController.dispose();
    _inviteHandleController.dispose();
    super.dispose();
  }

  bool get _isOwner => context.read<UserProfileController>().profile?.isOwner ?? false;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final org = await _service.fetchMyOrganization();
      var members = <Member>[];
      var ownerInvites = <Invite>[];
      var myInvites = <Invite>[];
      if (org != null) {
        members = await _service.fetchMembers(org.id);
        if (_isOwner) {
          ownerInvites = await _service.fetchOrgInvites(org.id);
        }
      } else {
        myInvites = await _service.fetchMyInvites();
      }
      if (!mounted) return;
      setState(() {
        _org = org;
        _members = members;
        _ownerInvites = ownerInvites;
        _myInvites = myInvites;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String message) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.t(AppStrings.cancel)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.t(AppStrings.save)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _createOrganization() async {
    final l10n = context.l10n;
    final name = _createNameController.text.trim();
    if (name.isEmpty) return;

    setState(() => _busy = true);
    try {
      await _service.createOrganization(name, _createSeatLimit);
      if (!mounted) return;
      await context.read<UserProfileController>().refresh();
      await _load();
    } on UserProfileException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError(l10n.t(AppStrings.orgCreateError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteOrganization() async {
    final l10n = context.l10n;
    final org = _org;
    if (org == null) return;
    final confirmed = await _confirm(
      l10n.t(AppStrings.orgDeleteConfirmTitle),
      l10n.t(AppStrings.orgDeleteConfirmMessage),
    );
    if (!confirmed) return;

    setState(() => _busy = true);
    try {
      await _service.deleteOrganization(org.id);
      if (!mounted) return;
      await context.read<UserProfileController>().refresh();
      await _load();
    } on UserProfileException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError(l10n.t(AppStrings.orgGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leaveOrganization() async {
    final l10n = context.l10n;
    final confirmed = await _confirm(
      l10n.t(AppStrings.orgLeaveConfirmTitle),
      l10n.t(AppStrings.orgLeaveConfirmMessage),
    );
    if (!confirmed) return;

    setState(() => _busy = true);
    try {
      await _service.leaveOrganization();
      if (!mounted) return;
      await context.read<UserProfileController>().refresh();
      await _load();
    } on UserProfileException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError(l10n.t(AppStrings.orgGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendInvite() async {
    final l10n = context.l10n;
    final org = _org;
    final handle = _inviteHandleController.text.trim();
    if (org == null || handle.isEmpty) return;

    setState(() => _busy = true);
    try {
      await _service.createInvite(org.id, handle);
      _inviteHandleController.clear();
      if (!mounted) return;
      _showError(l10n.t(AppStrings.orgInviteSentSuccess));
      await _load();
    } on UserProfileException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError(l10n.t(AppStrings.orgGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeInvite(Invite invite) async {
    final org = _org;
    if (org == null) return;
    setState(() => _respondingInviteIds.add(invite.id));
    try {
      await _service.revokeInvite(org.id, invite.id);
      if (!mounted) return;
      setState(() => _ownerInvites = _ownerInvites.where((i) => i.id != invite.id).toList());
    } on UserProfileException catch (e) {
      _showError(e.message);
    } catch (_) {
      if (!mounted) return;
      _showError(context.l10n.t(AppStrings.orgGenericError));
    } finally {
      if (mounted) setState(() => _respondingInviteIds.remove(invite.id));
    }
  }

  Future<void> _removeMember(Member member) async {
    final org = _org;
    if (org == null) return;
    setState(() => _busy = true);
    try {
      await _service.removeMember(org.id, member.id);
      if (!mounted) return;
      await _load();
    } on UserProfileException catch (e) {
      _showError(e.message);
    } catch (_) {
      if (!mounted) return;
      _showError(context.l10n.t(AppStrings.orgGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _respondToMyInvite(Invite invite, bool accept) async {
    setState(() => _respondingInviteIds.add(invite.id));
    try {
      if (accept) {
        await _service.acceptInvite(invite.id);
        if (!mounted) return;
        await context.read<UserProfileController>().refresh();
        await _load();
      } else {
        await _service.declineInvite(invite.id);
        if (!mounted) return;
        setState(() => _myInvites = _myInvites.where((i) => i.id != invite.id).toList());
      }
    } on UserProfileException catch (e) {
      _showError(e.message);
    } catch (_) {
      if (!mounted) return;
      _showError(context.l10n.t(AppStrings.orgGenericError));
    } finally {
      if (mounted) setState(() => _respondingInviteIds.remove(invite.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final profile = context.watch<UserProfileController>().profile;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t(AppStrings.orgScreenTitle))),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _org == null
                    ? _buildNoOrgView(context)
                    : (profile?.isOwner ?? false)
                        ? _buildOwnerView(context, _org!)
                        : _buildMemberView(context, _org!),
              ),
      ),
    );
  }

  Widget _buildNoOrgView(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.t(AppStrings.orgNoOrgDescription), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              TextFormField(
                controller: _createNameController,
                decoration: InputDecoration(labelText: l10n.t(AppStrings.orgCreateNameLabel)),
              ),
              const SizedBox(height: 12),
              Text(l10n.t(AppStrings.orgCreateSeatLimitLabel), style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 5, label: Text('5')),
                  ButtonSegment(value: 10, label: Text('10')),
                ],
                selected: {_createSeatLimit},
                onSelectionChanged: (selection) => setState(() => _createSeatLimit = selection.first),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _createOrganization,
                child: Text(l10n.t(AppStrings.orgCreateSubmit)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.t(AppStrings.orgInvitesPendingTitle), style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              if (_myInvites.isEmpty)
                Text(
                  l10n.t(AppStrings.orgNoPendingInvites),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                )
              else
                for (final invite in _myInvites) ...[
                  _InviteTile(
                    invite: invite,
                    busy: _respondingInviteIds.contains(invite.id),
                    trailing: _respondingInviteIds.contains(invite.id)
                        ? null
                        : [
                            TextButton(
                              onPressed: () => _respondToMyInvite(invite, false),
                              child: Text(l10n.t(AppStrings.orgInviteDecline)),
                            ),
                            FilledButton.tonal(
                              onPressed: () => _respondToMyInvite(invite, true),
                              child: Text(l10n.t(AppStrings.orgInviteAccept)),
                            ),
                          ],
                  ),
                  const SizedBox(height: 8),
                ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMemberView(BuildContext context, Organization org) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(org.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                l10n
                    .t(AppStrings.orgSeatUsage)
                    .replaceAll('{used}', '${org.seatUsed}')
                    .replaceAll('{limit}', '${org.seatLimit}'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.t(AppStrings.orgMembersTitle), style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              for (final member in _members) ...[
                _MemberTile(member: member),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: _busy ? null : _leaveOrganization,
          child: Text(l10n.t(AppStrings.orgLeaveButton)),
        ),
      ],
    );
  }

  Widget _buildOwnerView(BuildContext context, Organization org) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final myUserId = context.watch<UserProfileController>().profile?.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(org.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                l10n
                    .t(AppStrings.orgSeatUsage)
                    .replaceAll('{used}', '${org.seatUsed}')
                    .replaceAll('{limit}', '${org.seatLimit}'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.t(AppStrings.orgInviteByHandleLabel), style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _inviteHandleController,
                      decoration: InputDecoration(hintText: l10n.t(AppStrings.handleSetupHint)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _busy ? null : _sendInvite,
                    child: Text(l10n.t(AppStrings.orgInviteSubmit)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.t(AppStrings.orgInvitesPendingTitle), style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              if (_ownerInvites.isEmpty)
                Text(
                  l10n.t(AppStrings.orgNoPendingInvites),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                )
              else
                for (final invite in _ownerInvites) ...[
                  _InviteTile(
                    invite: invite,
                    busy: _respondingInviteIds.contains(invite.id),
                    trailing: _respondingInviteIds.contains(invite.id)
                        ? null
                        : [
                            TextButton(
                              onPressed: () => _revokeInvite(invite),
                              child: Text(l10n.t(AppStrings.orgInviteRevoke)),
                            ),
                          ],
                  ),
                  const SizedBox(height: 8),
                ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.t(AppStrings.orgMembersTitle), style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              for (final member in _members) ...[
                _MemberTile(
                  member: member,
                  onRemove: member.id == myUserId ? null : () => _removeMember(member),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: _busy ? null : _deleteOrganization,
          style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
          child: Text(l10n.t(AppStrings.orgDeleteButton)),
        ),
      ],
    );
  }
}

class _InviteTile extends StatelessWidget {
  const _InviteTile({required this.invite, required this.busy, this.trailing});

  final Invite invite;
  final bool busy;
  final List<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(invite.orgName, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                if (invite.invitedByHandle != null)
                  Text(
                    l10n.t(AppStrings.orgInvitedByLabel).replaceAll('{userName}', invite.invitedByHandle!),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else
            ...?trailing,
        ],
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member, this.onRemove});

  final Member member;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final label = member.displayName?.isNotEmpty == true
        ? member.displayName!
        : (member.handle ?? '');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          Text(
            member.orgRole,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: onRemove, child: Text(l10n.t(AppStrings.orgMemberRemove))),
          ],
        ],
      ),
    );
  }
}
