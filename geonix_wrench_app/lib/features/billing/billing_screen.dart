import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/auth_service.dart';
import '../../core/billing/billing_controller.dart';
import '../../core/config/app_config.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/models/billing_status.dart';
import '../../core/models/user_profile.dart';
import '../../core/services/billing_service.dart';
import '../../core/services/user_profile_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user/user_profile_controller.dart';
import '../../shared/widgets/block_layout.dart';
import '../../shared/widgets/surface_card.dart';

class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> with WidgetsBindingObserver {
  /// Fallback only, used until `/api/billing/status` reports the Team price.
  /// The server owns the advertised figure so the app, the website and the
  /// backend cannot drift apart; Stripe remains the source of truth at checkout.
  static const _fallbackPricePerSeat = 25.0;

  /// Fallback shown before the server reports the Individual plan price.
  static const _fallbackIndividualPrice = 29.0;

  /// Fallback floor used only until the server reports `min_seats`.
  static const _fallbackMinSeats = 2;

  late final BillingService _service;
  bool _busy = false;
  int _teamSeats = _fallbackMinSeats;
  bool _teamSeatsInitialized = false;
  bool _shopPromptOpen = false;

  /// The screen also offers the prompt on open, not just on returning from
  /// checkout — otherwise someone who closed the app mid-flow would come back
  /// to a paid Team plan with no way to finish it. Shown once per visit so a
  /// declined prompt does not immediately reappear.
  bool _shopPromptAutoShown = false;

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
    // Checkout happens in an external browser, so returning to the app is the
    // moment a new subscription becomes visible.
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshAndPromptForShop());
    }
  }

  /// Re-reads billing and, if Team seats were just bought without a shop,
  /// prompts for the shop name. The seats are already paid for, so this is the
  /// only step left before the plan is usable.
  Future<void> _refreshAndPromptForShop() async {
    final controller = context.read<BillingController>();
    // Authoritative: this is the moment a just-completed checkout should become
    // visible, so verify against Stripe rather than trusting the webhook.
    await controller.refresh(reconcile: true);
    if (!mounted) return;
    if (controller.status?.needsShop != true) return;
    await _promptForShopName(controller.status?.seatLimit);
  }

  Future<void> _promptForShopName(int? seats) async {
    // Guard against a second dialog stacking on the first if the app is
    // resumed again while this one is open.
    if (_shopPromptOpen) return;
    _shopPromptOpen = true;
    try {
      final created = await showShopNameDialog(context, seats: seats);
      if (!created || !mounted) return;
      // The shop now exists and owns the subscription: refresh both so the
      // screen switches to the active Team view with its seat manager.
      await context.read<UserProfileController>().refresh();
      if (!mounted) return;
      await context.read<BillingController>().refresh();
    } finally {
      _shopPromptOpen = false;
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Team price per seat.
  ///
  /// `price_per_seat` is scope-dependent — it quotes the Team price only on an
  /// org — so it is used as a fallback only when the scope confirms its
  /// meaning. Reading it unconditionally made the Team card advertise the
  /// Individual price to every user who did not yet have a shop.
  double _teamPricePerSeat(BillingStatus? status) =>
      status?.teamPricePerSeat ??
      (status != null && status.isOrgScope ? status.pricePerSeat : null) ??
      _fallbackPricePerSeat;

  /// Individual price per month, disambiguated the same way.
  double _individualPrice(BillingStatus? status) =>
      status?.individualPrice ??
      (status != null && !status.isOrgScope ? status.pricePerSeat : null) ??
      _fallbackIndividualPrice;

  String _money(double amount) =>
      NumberFormat('#,##0.00', context.l10n.locale.toString()).format(amount);

  String _symbol(BillingStatus? status) =>
      const {'EUR': '€', 'USD': '\$', 'GBP': '£'}[status?.currency ?? 'EUR'] ?? '€';

  /// Headline price: whole amounts drop the ".00" so the figure stays large and
  /// readable, anything else keeps its cents.
  String _priceLabel(BillingStatus? status, double amount) {
    final symbol = _symbol(status);
    final whole = amount == amount.roundToDouble();
    return '$symbol${whole ? amount.toStringAsFixed(0) : _money(amount)}';
  }

  /// The Team plan's seat minimum.
  ///
  /// `min_seats` describes the caller's *current* plan, so it reports 1 for
  /// anyone not already on Team. The Team card is shown in every scope, so its
  /// floor comes from `team_min_seats`, which is quoted unconditionally.
  int _teamMinSeats(BillingStatus? status) =>
      status?.teamMinSeats ??
      (status != null && status.isOrgScope ? status.minSeats : null) ??
      _fallbackMinSeats;

  /// Seat floor for the stepper: never below the plan minimum, and never below
  /// the seats already occupied.
  int _seatFloor(BillingStatus? status) {
    final minSeats = _teamMinSeats(status);
    // Never below the seats already occupied — the backend refuses to oversell
    // too, and a stepper that allows it just produces a rejected request.
    final used = status?.seatUsed ?? 0;
    return minSeats > used ? minSeats : used;
  }

  Future<void> _subscribe(String plan, {int? quantity}) async {
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      final checkoutUrl = await _service.createCheckoutSession(
        plan: plan,
        quantity: quantity,
        successUrl: kCheckoutSuccessUrl,
        cancelUrl: kCheckoutCancelUrl,
      );
      final launched =
          await launchUrl(Uri.parse(checkoutUrl), mode: LaunchMode.externalApplication);
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

  Future<void> _updateSeats() async {
    final l10n = context.l10n;
    final controller = context.read<BillingController>();
    final previous = controller.status?.seatLimit;
    setState(() => _busy = true);
    try {
      await controller.updateSeats(_teamSeats);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.t(AppStrings.billingSeatsUpdated).replaceAll('{seats}', '$_teamSeats'),
          ),
        ),
      );
    } on BillingException catch (e) {
      // Snap the stepper back so it never shows a count that was not purchased.
      if (previous != null) _teamSeats = previous;
      _showError(e.message);
    } catch (_) {
      if (previous != null) _teamSeats = previous;
      _showError(l10n.t(AppStrings.billingGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBillingPortal() async {
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      final url = await _service.createPortalSession(returnUrl: kCheckoutSuccessUrl);
      final launched =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!launched) _showError(l10n.t(AppStrings.billingLaunchError));
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
      final floor = _seatFloor(status);
      _teamSeats = seatLimit < floor ? floor : seatLimit;
      _teamSeatsInitialized = true;
    }

    if (status?.needsShop == true && !_shopPromptAutoShown && !_shopPromptOpen) {
      _shopPromptAutoShown = true;
      // Deferred: a dialog cannot be pushed during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _promptForShopName(status?.seatLimit);
      });
    }

    return BlockScaffold(
      header: BlockTitleHeader(title: l10n.t(AppStrings.billingScreenTitle)),
      child: billing.isInitialLoad
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.space5,
                AppTheme.space6,
                AppTheme.space5,
                AppTheme.space10,
              ),
              child: Center(
                child: ConstrainedBox(
                  // Keeps the cards readable on a wide desktop window instead
                  // of stretching one column across the whole screen.
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: billing.isActive && status != null
                      ? _buildActiveView(context, status)
                      : _buildPlansView(context, profile, status),
                ),
              ),
            ),
    );
  }

  // ---------------------------------------------------------------- active

  Widget _buildActiveView(BuildContext context, BillingStatus status) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final isTrialing = status.status == 'trialing';

    String? renewsLabel;
    if (status.currentPeriodEnd != null) {
      final parsed = DateTime.tryParse(status.currentPeriodEnd!);
      if (parsed != null) {
        renewsLabel = l10n
            .t(AppStrings.billingRenewsLabel)
            .replaceAll('{date}', DateFormat.yMMMd(l10n.locale.toString()).format(parsed));
      }
    }

    // Keyed on the plan, not the scope: a Team subscription bought before the
    // shop exists is still user-scoped, and reading the scope labelled it
    // "Individual" on the very screen confirming the Team purchase.
    final planName = (status.plan ?? (status.isOrgScope ? 'team' : 'individual')) == 'team'
        ? l10n.t(AppStrings.billingPlanTeamName)
        : l10n.t(AppStrings.billingPlanIndividualName);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.t(AppStrings.billingCurrentPlanLabel).toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            letterSpacing: 0.8,
                            fontWeight: FontWeight.w600,
                            color: p.inkTertiary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          planName,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _StatusPill(
                    label: isTrialing
                        ? l10n.t(AppStrings.billingStatusTrialing)
                        : l10n.t(AppStrings.billingStatusActive),
                    color: isTrialing ? p.accent : p.success,
                  ),
                ],
              ),
              if (renewsLabel != null) ...[
                const SizedBox(height: 14),
                _MetaRow(icon: Icons.event_repeat_outlined, label: renewsLabel),
              ],
              if (status.isOrgScope && status.seatLimit != null && status.seatUsed != null) ...[
                const SizedBox(height: 10),
                _MetaRow(
                  icon: Icons.groups_outlined,
                  label: l10n
                      .t(AppStrings.billingSeatUsage)
                      .replaceAll('{used}', '${status.seatUsed}')
                      .replaceAll('{limit}', '${status.seatLimit}'),
                ),
                const SizedBox(height: 12),
                _SeatBar(used: status.seatUsed!, limit: status.seatLimit!),
              ],
            ],
          ),
        ),
        if (status.canManageSeats) ...[
          const SizedBox(height: AppTheme.space4),
          _buildSeatManager(context, status),
        ],
        const SizedBox(height: AppTheme.space4),
        _buildManageCard(context),
      ],
    );
  }

  /// Cancel / payment method / invoices, all hosted by Stripe. Before this the
  /// only way to cancel was to email us.
  Widget _buildManageCard(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.t(AppStrings.billingManageButton),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppTheme.space1),
          Text(
            l10n.t(AppStrings.billingManageDescription),
            style: theme.textTheme.bodyMedium?.copyWith(color: p.inkSecondary),
          ),
          const SizedBox(height: AppTheme.space5),
          OutlinedButton.icon(
            onPressed: _busy ? null : _openBillingPortal,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(l10n.t(AppStrings.billingManageButton)),
          ),
        ],
      ),
    );
  }

  /// Post-purchase seat management. Buying seats was always possible at
  /// checkout, but the count was then frozen — this lets the owner change it.
  Widget _buildSeatManager(BuildContext context, BillingStatus status) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final floor = _seatFloor(status);
    final minSeats = status.minSeats ?? _fallbackMinSeats;
    final seatsUsed = status.seatUsed ?? 0;
    final changed = _teamSeats != status.seatLimit;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.t(AppStrings.billingManageSeatsTitle),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.t(AppStrings.billingManageSeatsDescription),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: p.inkSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          _SeatSelector(
            seats: _teamSeats,
            minimum: floor,
            onChanged: _busy ? null : (value) => setState(() => _teamSeats = value),
          ),
          const SizedBox(height: 10),
          Text(
            // Explain whichever constraint is actually binding, so a disabled
            // minus button never looks like a bug.
            seatsUsed > minSeats
                ? l10n.t(AppStrings.billingSeatsInUseNote).replaceAll('{used}', '$seatsUsed')
                : l10n.t(AppStrings.billingSeatsMinimumNote).replaceAll('{min}', '$minSeats'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: p.inkTertiary,
            ),
          ),
          const SizedBox(height: 18),
          _TotalRow(
            seats: _teamSeats,
            pricePerSeat: _teamPricePerSeat(status),
            symbol: _symbol(status),
          ),
          const SizedBox(height: 18),
          FilledButton(
            // Nothing to charge if the count has not moved.
            onPressed: _busy || !changed ? null : _updateSeats,
            child: Text(l10n.t(AppStrings.billingUpdateSeatsButton)),
          ),
          if (changed) ...[
            const SizedBox(height: 10),
            Text(
              l10n.t(AppStrings.billingSeatsProrationNote),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: p.inkTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ----------------------------------------------------------------- plans

  Widget _buildPlansView(BuildContext context, UserProfile? profile, BillingStatus? status) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final hasOrganization = profile?.hasOrganization ?? false;
    final isOwner = profile?.isOwner ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          l10n.t(AppStrings.billingPlansTitle),
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.t(AppStrings.billingPlansSubtitle),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: p.inkSecondary,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        _buildIndividualCard(context, status, hasOrganization: hasOrganization),
        const SizedBox(height: 16),
        // The Team card is always rendered. It used to be hidden entirely for
        // anyone without a shop, which left no way to discover or reach the
        // plan at all — you had to already have a shop to be told it existed.
        _buildTeamCard(
          context,
          status,
          hasOrganization: hasOrganization,
          isOwner: isOwner,
        ),
      ],
    );
  }

  Widget _buildIndividualCard(
    BuildContext context,
    BillingStatus? status, {
    required bool hasOrganization,
  }) {
    final l10n = context.l10n;

    return _PlanCard(
      title: l10n.t(AppStrings.billingIndividualPlanTitle),
      description: l10n.t(AppStrings.billingIndividualPlanDescription),
      price: _priceLabel(status, _individualPrice(status)),
      priceCaption: l10n.t(AppStrings.billingPerMonth),
      dimmed: hasOrganization,
      features: [
        l10n.t(AppStrings.billingFeatureUnlimitedCards),
        l10n.t(AppStrings.billingFeaturePdfExport),
        l10n.t(AppStrings.billingFeatureShopLogo),
      ],
      child: hasOrganization
          ? _InfoNote(text: l10n.t(AppStrings.billingIndividualUnavailableNote))
          : FilledButton(
              onPressed: _busy ? null : () => _subscribe('individual'),
              child: Text(l10n.t(AppStrings.billingSubscribeButton)),
            ),
    );
  }

  Widget _buildTeamCard(
    BuildContext context,
    BillingStatus? status, {
    required bool hasOrganization,
    required bool isOwner,
  }) {
    final l10n = context.l10n;
    final p = context.palette;

    final Widget action;
    if (hasOrganization && !isOwner) {
      action = _InfoNote(text: l10n.t(AppStrings.billingTeamRequiresOwnerNote));
    } else {
      // Seats are chosen and bought up front, whether or not the shop exists
      // yet. Requiring a shop first was a dead end: you had to guess a seat
      // count while creating the shop, then pay for it as a separate step.
      // Without a shop the flow now runs subscribe -> name the shop.
      final minimum = _seatFloor(status);
      final seats = _teamSeats < minimum ? minimum : _teamSeats;

      action = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!hasOrganization) ...[
            _InfoNote(text: l10n.t(AppStrings.billingTeamNeedsShopNote)),
            const SizedBox(height: 18),
          ],
          Text(
            l10n.t(AppStrings.billingSeatsLabel),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          _SeatSelector(
            seats: seats,
            minimum: minimum,
            onChanged: _busy ? null : (value) => setState(() => _teamSeats = value),
          ),
          const SizedBox(height: 10),
          // States the binding minimum outright, so the disabled minus button
          // never reads as a broken control.
          Text(
            l10n.t(AppStrings.billingSeatsMinimumNote).replaceAll('{min}', '$minimum'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.inkTertiary),
          ),
          const SizedBox(height: 16),
          _TotalRow(
            seats: seats,
            pricePerSeat: _teamPricePerSeat(status),
            symbol: _symbol(status),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _busy ? null : () => _subscribe('team', quantity: seats),
            child: Text(l10n.t(AppStrings.billingSubscribeButton)),
          ),
        ],
      );
    }

    return _PlanCard(
      title: l10n.t(AppStrings.billingTeamPlanTitle),
      description: l10n.t(AppStrings.billingTeamPlanDescription),
      price: _priceLabel(status, _teamPricePerSeat(status)),
      priceCaption: l10n.t(AppStrings.billingPerSeatMonth),
      highlighted: hasOrganization,
      features: [
        l10n.t(AppStrings.billingFeatureSharedShop),
        l10n.t(AppStrings.billingFeaturePdfExport),
        l10n.t(AppStrings.billingFeatureSeatControl),
      ],
      child: action,
    );
  }
}

/// Asks for the shop's name after the Team seats have been paid for.
///
/// Deliberately name-only: the seat limit is whatever the subscription bought,
/// and the server derives it. Offering a seat field here would let a shop be
/// created with a count that was never purchased.
///
/// Returns true when the shop was created.
Future<bool> showShopNameDialog(BuildContext context, {int? seats}) async {
  final created = await showDialog<bool>(
    context: context,
    // The seats are already charged for, so this must be finished rather than
    // dismissed into a state where the plan is paid but unusable.
    barrierDismissible: false,
    builder: (_) => _ShopNameDialog(seats: seats),
  );
  return created ?? false;
}

class _ShopNameDialog extends StatefulWidget {
  const _ShopNameDialog({this.seats});

  final int? seats;

  @override
  State<_ShopNameDialog> createState() => _ShopNameDialogState();
}

class _ShopNameDialogState extends State<_ShopNameDialog> {
  final TextEditingController _name = TextEditingController();
  late final UserProfileService _service;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = UserProfileService(authService: context.read<AuthService>());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.t(AppStrings.billingCreateShopNameRequired));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.createOrganization(name);
      if (mounted) Navigator.of(context).pop(true);
    } on UserProfileException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.t(AppStrings.billingCreateShopError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final seats = widget.seats;

    return AlertDialog(
      title: Text(l10n.t(AppStrings.billingCreateShopTitle)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            seats == null
                ? l10n.t(AppStrings.billingTeamNeedsShopNote)
                : l10n
                    .t(AppStrings.billingCreateShopPrompt)
                    .replaceAll('{seats}', '$seats'),
            style: theme.textTheme.bodyMedium?.copyWith(color: p.inkSecondary),
          ),
          const SizedBox(height: AppTheme.space5),
          TextField(
            controller: _name,
            autofocus: true,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: _busy ? null : (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.t(AppStrings.billingCreateShopNameLabel),
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        // An escape hatch: if the server is unreachable right now, refusing to
        // let go would strand the user on a dialog they cannot complete. The
        // prompt returns on the next visit, and the seats stay paid for.
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.t(AppStrings.billingCreateShopLater)),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.t(AppStrings.billingCreateShopButton)),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- components

/// A plan card with a real price hierarchy: the figure reads first, the
/// qualifier sits next to it, and the feature list is scannable.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.title,
    required this.description,
    required this.price,
    required this.priceCaption,
    required this.features,
    required this.child,
    this.highlighted = false,
    this.dimmed = false,
  });

  final String title;
  final String description;
  final String price;
  final String priceCaption;
  final List<String> features;
  final Widget child;
  final bool highlighted;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;

    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: SurfaceCard(
        padding: const EdgeInsets.all(AppTheme.space6),
        radius: AppTheme.radiusXl,
        accented: highlighted,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
                // The recommended plan says so, rather than relying on a 1.5px
                // tinted edge nobody reads as "pick this one".
                if (highlighted)
                  const ToneChip(label: 'Recommended', tone: ChipTone.accent),
              ],
            ),
            const SizedBox(height: AppTheme.space2),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: p.inkSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: AppTheme.space5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  price,
                  style: theme.textTheme.displayMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: AppTheme.space2),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    priceCaption,
                    style: theme.textTheme.bodySmall?.copyWith(color: p.inkTertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.space5),
            for (final feature in features) ...[
              _FeatureRow(text: feature),
              const SizedBox(height: AppTheme.space3),
            ],
            const SizedBox(height: AppTheme.space4),
            child,
          ],
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Icon(Icons.check_rounded, size: 16, color: p.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
        ),
      ],
    );
  }
}

/// Thin wrapper over the shared [ToneChip] so the billing screen's status
/// badge is literally the same component as the record screen's.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ToneChip(
      label: label,
      dotColor: color,
      background: color.withValues(alpha: 0.12),
      foreground: color,
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final muted = p.inkSecondary;
    return Row(
      children: [
        Icon(icon, size: 16, color: muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
      ],
    );
  }
}

/// Occupancy bar for the shop's seats — turns "3/5 seats used" into something
/// readable at a glance.
class _SeatBar extends StatelessWidget {
  const _SeatBar({required this.used, required this.limit});

  final int used;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fraction = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);
    final full = used >= limit;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      child: LinearProgressIndicator(
        value: fraction,
        minHeight: 6,
        backgroundColor: p.surfaceMuted,
        valueColor: AlwaysStoppedAnimation<Color>(
          full ? p.accent : p.success,
        ),
      ),
    );
  }
}

class _InfoNote extends StatelessWidget {
  const _InfoNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    return SurfaceWell(
      padding: const EdgeInsets.all(AppTheme.space4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: p.inkTertiary,
            ),
          ),
          const SizedBox(width: AppTheme.space3),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: p.inkSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({
    required this.seats,
    required this.pricePerSeat,
    required this.symbol,
  });

  final String symbol;

  final int seats;
  final double pricePerSeat;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;

    return SurfaceWell(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            // Price is substituted rather than baked into the string, so the
            // caption follows whatever the server advertises.
            l10n.t(AppStrings.billingSeatsPerSeatPrice).replaceAll(
                  '{price}',
                  '$symbol${NumberFormat('#,##0.00', l10n.locale.toString()).format(pricePerSeat)}',
                ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: p.inkSecondary,
            ),
          ),
          Text(
            l10n.t(AppStrings.billingSeatsTotalPrice).replaceAll(
                  '{total}',
                  // Grouped: seats are uncapped, so this total can reach four
                  // and five figures.
                  '$symbol${NumberFormat('#,##0.00', l10n.locale.toString()).format(pricePerSeat * seats)}',
                ),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              // Tabular figures stop the total from jittering as digits change.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
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

  /// Null while a purchase or seat update is in flight, which disables both
  /// steppers rather than letting the count drift under the request.
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final onChanged = this.onChanged;

    return SurfaceWell(
      padding: const EdgeInsets.all(AppTheme.space1 + 2),
      child: Row(
        children: [
          IconButton.filledTonal(
            onPressed: onChanged != null && seats > minimum ? () => onChanged(seats - 1) : null,
            tooltip: l10n.t(AppStrings.billingSeatDecrease),
            icon: const Icon(Icons.remove, size: 20),
          ),
          Expanded(
            child: Center(
              child: Text(
                '$seats',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          IconButton.filledTonal(
            onPressed: onChanged == null ? null : () => onChanged(seats + 1),
            tooltip: l10n.t(AppStrings.billingSeatIncrease),
            icon: const Icon(Icons.add, size: 20),
          ),
        ],
      ),
    );
  }
}
