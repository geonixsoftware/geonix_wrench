import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_service.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/models/invite.dart';
import '../../core/services/user_profile_service.dart';
import '../../core/user/user_profile_controller.dart';
import '../../shared/widgets/block_layout.dart';
import '../../shared/widgets/surface_card.dart';
import 'login_screen.dart';
import '../../core/theme/app_theme.dart';

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
      await _service.createOrganization(name);
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
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return AuthBlockScaffold(
      title: l10n.t(AppStrings.orgOnboardingTitle),
      subtitle: l10n.t(AppStrings.orgOnboardingDescription),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_showCreateForm) ...[
            // The two paths are given equal weight as picture-led cards
            // instead of a stacked button pair, because "work solo" is a real
            // choice here and not a dismissal.
            SurfaceCard(
              padding: const EdgeInsets.all(AppTheme.space5),
              onTap: () => setState(() => _showCreateForm = true),
              child: Row(
                children: [
                  const IconTile(Icons.storefront_outlined, size: 46, tone: TileTone.accent),
                  const SizedBox(width: AppTheme.space4),
                  Expanded(
                    child: Text(
                      l10n.t(AppStrings.orgOnboardingCreateShop),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: p.inkTertiary),
                ],
              ),
            ),
            const SizedBox(height: AppTheme.space3),
            SurfaceCard(
              padding: const EdgeInsets.all(AppTheme.space5),
              onTap: widget.onSkip,
              child: Row(
                children: [
                  const IconTile(Icons.person_outline_rounded, size: 46),
                  const SizedBox(width: AppTheme.space4),
                  Expanded(
                    child: Text(
                      l10n.t(AppStrings.orgOnboardingSkip),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: p.inkTertiary),
                ],
              ),
            ),
          ] else ...[
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.t(AppStrings.orgCreateNameLabel),
                prefixIcon: const Icon(Icons.storefront_outlined),
              ),
            ),
            // No seat picker: the shop gets exactly the seats its owner's Team
            // subscription paid for, which the server owns. Choosing a number
            // here produced shops with more seats than were ever purchased.
            const SizedBox(height: AppTheme.space6),
            ElevatedButton(
              onPressed: _creating ? null : _createOrganization,
              child: _creating
                  ? SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: p.onAccent),
                    )
                  : Text(l10n.t(AppStrings.orgCreateSubmit)),
            ),
            const SizedBox(height: AppTheme.space2),
            TextButton(
              onPressed: _creating ? null : () => setState(() => _showCreateForm = false),
              child: Text(l10n.t(AppStrings.cancel)),
            ),
          ],
          const SizedBox(height: AppTheme.space10),
          SectionHeading(title: l10n.t(AppStrings.orgOnboardingPendingInvitesTitle)),
          const SizedBox(height: AppTheme.space4),
          if (_loadingInvites)
            const Center(child: CircularProgressIndicator(strokeWidth: 2))
          else if (_invites.isEmpty)
            SurfaceWell(
              radius: AppTheme.radiusLg,
              padding: const EdgeInsets.symmetric(
                vertical: AppTheme.space6,
                horizontal: AppTheme.space5,
              ),
              child: Text(
                l10n.t(AppStrings.orgNoPendingInvites),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: p.inkTertiary),
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
              if (invite != _invites.last) const SizedBox(height: AppTheme.space3),
            ],
        ],
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
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.all(AppTheme.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const IconTile(Icons.mark_email_unread_outlined, size: 42),
              const SizedBox(width: AppTheme.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(invite.orgName, style: theme.textTheme.titleSmall),
                    if (invite.invitedByHandle != null)
                      Text(
                        l10n
                            .t(AppStrings.orgInvitedByLabel)
                            .replaceAll('{userName}', invite.invitedByHandle!),
                        style: theme.textTheme.bodySmall?.copyWith(color: p.inkTertiary),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.space4),
          if (busy)
            const Center(
              child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            // Full-width side-by-side rather than two right-aligned links: on a
            // phone the old row put Decline and Accept a thumb-width apart at
            // the far edge of the card.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onDecline,
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                    child: Text(l10n.t(AppStrings.orgInviteDecline)),
                  ),
                ),
                const SizedBox(width: AppTheme.space3),
                Expanded(
                  child: FilledButton(
                    onPressed: onAccept,
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    child: Text(l10n.t(AppStrings.orgInviteAccept)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
