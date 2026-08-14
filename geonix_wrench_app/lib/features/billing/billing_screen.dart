import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/auth_service.dart';
import '../../core/billing/billing_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/models/billing_status.dart';
import '../../core/models/user_profile.dart';
import '../../core/services/billing_service.dart';
import '../../core/user/user_profile_controller.dart';
import '../../shared/widgets/surface_card.dart';

class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> with WidgetsBindingObserver {
  static const _successUrl = 'https://geonixsoftware.com/wrench-billing-success.html';
  static const _cancelUrl = 'https://geonixsoftware.com/wrench-billing-cancel.html';

  late final BillingService _service;
  bool _busy = false;
  int _teamSeats = 2;
  bool _teamSeatsInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service = BillingService(authService: context.read<AuthService>());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<BillingController>().refresh();
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _subscribe(String plan, {int? quantity}) async {
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      final checkoutUrl = await _service.createCheckoutSession(
        plan: plan,
        quantity: quantity,
        successUrl: _successUrl,
        cancelUrl: _cancelUrl,
      );
      final launched = await launchUrl(Uri.parse(checkoutUrl), mode: LaunchMode.externalApplication);
      if (!launched) {
        _showError(l10n.t(AppStrings.billingLaunchError));
      }
    } on BillingException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError(l10n.t(AppStrings.billingGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final billing = context.watch<BillingController>();
    final profile = context.watch<UserProfileController>().profile;
    final status = billing.status;

    final seatLimit = status?.seatLimit;
    if (seatLimit != null && !_teamSeatsInitialized) {
      _teamSeats = seatLimit < 2 ? 2 : seatLimit;
      _teamSeatsInitialized = true;
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t(AppStrings.billingScreenTitle))),
      body: SafeArea(
        child: billing.isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: billing.isActive && status != null
                    ? _buildActiveView(context, status)
                    : _buildPlansView(context, profile),
              ),
      ),
    );
  }

  Widget _buildActiveView(BuildContext context, BillingStatus status) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    String? renewsLabel;
    if (status.currentPeriodEnd != null) {
      final parsed = DateTime.tryParse(status.currentPeriodEnd!);
      if (parsed != null) {
        renewsLabel = l10n
            .t(AppStrings.billingRenewsLabel)
            .replaceAll('{date}', DateFormat.yMMMd(l10n.locale.toString()).format(parsed));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.t(AppStrings.billingActiveTitle), style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                status.status == 'trialing'
                    ? l10n.t(AppStrings.billingStatusTrialing)
                    : l10n.t(AppStrings.billingStatusActive),
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
              ),
              if (renewsLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  renewsLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
              if (status.isOrgScope && status.seatLimit != null && status.seatUsed != null) ...[
                const SizedBox(height: 4),
                Text(
                  l10n
                      .t(AppStrings.billingSeatUsage)
                      .replaceAll('{used}', '${status.seatUsed}')
                      .replaceAll('{limit}', '${status.seatLimit}'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlansView(BuildContext context, UserProfile? profile) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final hasOrganization = profile?.hasOrganization ?? false;
    final isOwner = profile?.isOwner ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.t(AppStrings.billingPlansTitle), style: theme.textTheme.titleLarge),
        const SizedBox(height: 16),
        if (!hasOrganization)
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.t(AppStrings.billingIndividualPlanTitle), style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  l10n.t(AppStrings.billingIndividualPlanDescription),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : () => _subscribe('individual'),
                  child: Text(l10n.t(AppStrings.billingSubscribeButton)),
                ),
              ],
            ),
          ),
        if (hasOrganization) ...[
          const SizedBox(height: 20),
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.t(AppStrings.billingTeamPlanTitle), style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(l10n.t(AppStrings.billingTeamPlanDescription), style: theme.textTheme.bodyMedium),
                if (!isOwner) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.t(AppStrings.billingTeamRequiresOwnerNote),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 16),
                  Text(l10n.t(AppStrings.billingSeatsLabel), style: theme.textTheme.labelMedium),
                  const SizedBox(height: 8),
                  _SeatSelector(
                    seats: _teamSeats,
                    minimum: 2,
                    onChanged: (value) => setState(() => _teamSeats = value),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.t(AppStrings.billingSeatsPerSeatPrice),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      Text(
                        l10n.t(AppStrings.billingSeatsTotalPrice).replaceAll(
                          '{total}',
                          '€${(27.0 * _teamSeats).toStringAsFixed(2)}',
                        ),
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : () => _subscribe('team', quantity: _teamSeats),
                    child: Text(l10n.t(AppStrings.billingSubscribeButton)),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ],
    );
  }
}

class _SeatSelector extends StatelessWidget {
  const _SeatSelector({
    required this.seats,
    required this.minimum,
    required this.onChanged,
  });

  final int seats;
  final int minimum;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Row(
      children: [
        IconButton.filledTonal(
          onPressed: seats > minimum ? () => onChanged(seats - 1) : null,
          tooltip: l10n.t(AppStrings.billingSeatDecrease),
          icon: const Icon(Icons.remove),
        ),
        Expanded(
          child: Center(
            child: Text(
              '$seats',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        IconButton.filledTonal(
          onPressed: () => onChanged(seats + 1),
          tooltip: l10n.t(AppStrings.billingSeatIncrease),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}
