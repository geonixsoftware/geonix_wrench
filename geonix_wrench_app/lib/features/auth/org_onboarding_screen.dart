import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_service.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/models/invite.dart';
import '../../core/services/user_profile_service.dart';
import '../../core/user/user_profile_controller.dart';
import '../../shared/widgets/surface_card.dart';

class OrgOnboardingScreen extends StatefulWidget {
  const OrgOnboardingScreen({super.key, required this.onSkip});

  final VoidCallback onSkip;

  @override
  State<OrgOnboardingScreen> createState() => _OrgOnboardingScreenState();
}

class _OrgOnboardingScreenState extends State<OrgOnboardingScreen> {
  late final UserProfileService _service;
  bool _showCreateForm = false;
  bool _creating = false;
  int _seatLimit = 5;
  final _nameController = TextEditingController();

  bool _loadingInvites = true;
  List<Invite> _invites = [];
  final Set<int> _respondingInviteIds = {};

  @override
  void initState() {
    super.initState();
    _service = UserProfileService(authService: context.read<AuthService>());
    _loadInvites();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadInvites() async {
    try {
      final invites = await _service.fetchMyInvites();
      if (!mounted) return;
      setState(() {
        _invites = invites;
        _loadingInvites = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingInvites = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _createOrganization() async {
    final l10n = context.l10n;
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() => _creating = true);
    try {
      await _service.createOrganization(name, _seatLimit);
      if (!mounted) return;
      await context.read<UserProfileController>().refresh();
    } on UserProfileException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError(l10n.t(AppStrings.orgCreateError));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _respondToInvite(Invite invite, bool accept) async {
    setState(() => _respondingInviteIds.add(invite.id));
    try {
      if (accept) {
        await _service.acceptInvite(invite.id);
        if (!mounted) return;
        await context.read<UserProfileController>().refresh();
      } else {
        await _service.declineInvite(invite.id);
        if (!mounted) return;
        setState(() => _invites = _invites.where((i) => i.id != invite.id).toList());
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
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(l10n.t(AppStrings.orgOnboardingTitle), style: theme.textTheme.titleLarge),
                        const SizedBox(height: 12),
                        Text(
                          l10n.t(AppStrings.orgOnboardingDescription),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (!_showCreateForm) ...[
                          ElevatedButton(
                            onPressed: () => setState(() => _showCreateForm = true),
                            child: Text(l10n.t(AppStrings.orgOnboardingCreateShop)),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: widget.onSkip,
                            child: Text(l10n.t(AppStrings.orgOnboardingSkip)),
                          ),
                        ] else ...[
                          TextFormField(
                            controller: _nameController,
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
                            selected: {_seatLimit},
                            onSelectionChanged: (selection) => setState(() => _seatLimit = selection.first),
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton(
                            onPressed: _creating ? null : _createOrganization,
                            child: _creating
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : Text(l10n.t(AppStrings.orgCreateSubmit)),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _creating ? null : () => setState(() => _showCreateForm = false),
                            child: Text(l10n.t(AppStrings.cancel)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(l10n.t(AppStrings.orgOnboardingPendingInvitesTitle), style: theme.textTheme.titleMedium),
                        const SizedBox(height: 12),
                        if (_loadingInvites)
                          const Center(child: CircularProgressIndicator(strokeWidth: 2))
                        else if (_invites.isEmpty)
                          Text(
                            l10n.t(AppStrings.orgNoPendingInvites),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          )
                        else
                          for (final invite in _invites) ...[
                            _InviteRow(
                              invite: invite,
                              busy: _respondingInviteIds.contains(invite.id),
                              onAccept: () => _respondToInvite(invite, true),
                              onDecline: () => _respondToInvite(invite, false),
                            ),
                            const SizedBox(height: 8),
                          ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InviteRow extends StatelessWidget {
  const _InviteRow({
    required this.invite,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  final Invite invite;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

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
          else ...[
            TextButton(onPressed: onDecline, child: Text(l10n.t(AppStrings.orgInviteDecline))),
            FilledButton.tonal(onPressed: onAccept, child: Text(l10n.t(AppStrings.orgInviteAccept))),
          ],
        ],
      ),
    );
  }
}
