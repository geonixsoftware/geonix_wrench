import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_service.dart';
import '../../core/billing/billing_controller.dart';
import '../../core/billing/billing_gate.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/models/job_card.dart';
import '../../core/services/jobcard_update_service.dart';
import '../../core/services/pdf_service.dart';
import '../../core/settings/app_settings.dart';
import '../../core/utils/duration_formatter.dart';
import '../../shared/widgets/app_header.dart';
import '../../shared/widgets/block_layout.dart';
import '../../shared/widgets/surface_card.dart';
import 'widgets/job_card_field_tile.dart';
import 'widgets/job_card_parts_table.dart';
import '../../core/theme/app_theme.dart';

class JobCardReviewView extends StatefulWidget {
  const JobCardReviewView({super.key, required this.jobCard});

  final JobCard jobCard;

  @override
  State<JobCardReviewView> createState() => _JobCardReviewViewState();
}

class _JobCardReviewViewState extends State<JobCardReviewView> {
  late final PdfService _pdfService;
  late final JobCardUpdateService _updateService;
  late final TextEditingController _laborRateController;
  late final List<PartEditControllers> _partControllers;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    final authService = context.read<AuthService>();
    _pdfService = PdfService(
      authService: authService,
      pdfDirectory: context.read<AppSettings>().pdfDirectory,
    );
    _updateService = JobCardUpdateService(authService: authService);
    _laborRateController = TextEditingController(
      text: widget.jobCard.laborRate != null ? widget.jobCard.laborRate!.toStringAsFixed(2) : '',
    );
    _partControllers = widget.jobCard.partsUsed.map(PartEditControllers.new).toList();
  }

  @override
  void dispose() {
    _laborRateController.dispose();
    for (final controller in _partControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  JobCard _buildEditedCard() {
    final card = widget.jobCard;
    final editedParts = <PartUsed>[
      for (var i = 0; i < card.partsUsed.length; i++)
        PartUsed(
          partName: card.partsUsed[i].partName,
          quantity: int.tryParse(_partControllers[i].quantityController.text) ?? card.partsUsed[i].quantity,
          unitPrice: _partControllers[i].unitPriceController.text.trim().isEmpty
              ? null
              : double.tryParse(_partControllers[i].unitPriceController.text),
        ),
    ];

    return JobCard(
      id: card.id,
      vehicleInfo: card.vehicleInfo,
      laborHours: card.laborHours,
      laborRate: _laborRateController.text.trim().isEmpty ? null : double.tryParse(_laborRateController.text),
      workPerformed: card.workPerformed,
      partsUsed: editedParts,
      unbilledItemsFlagged: card.unbilledItemsFlagged,
      transcript: card.transcript,
    );
  }

  Future<void> _saveAndGeneratePdf(AppCurrency currency) async {
    if (!context.read<BillingController>().isActive) {
      await showSubscriptionRequiredDialog(context);
      return;
    }
    setState(() => _generating = true);
    final l10n = context.l10n;
    final editedCard = _buildEditedCard();
    try {
      await _updateService.update(editedCard);
      final saved = await _pdfService.generate(editedCard, currency);
      if (!mounted) return;
      // Name the folder it landed in. "PDF saved" with no location was the
      // whole reason the file felt lost.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.t(AppStrings.jobCardPdfSaved)} · ${saved.parent.path}',
          ),
        ),
      );
    } on PdfFetchException catch (e) {
      if (!mounted) return;
      if (e.isPaymentRequired) {
        // Server-side gate rejected the request (HTTP 402) — the subscription
        // check now lives on the backend, not in the client's cached state.
        await showSubscriptionRequiredDialog(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.t(AppStrings.jobCardPdfError))),
        );
      }
    } on JobCardUpdateException catch (e) {
      if (!mounted) return;
      if (e.isPaymentRequired) {
        await showSubscriptionRequiredDialog(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.t(AppStrings.jobCardUpdateError))),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t(AppStrings.jobCardPdfError))),
      );
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _tryAgain() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final currency = context.watch<AppSettings>().currency;
    final card = widget.jobCard;
    final flagCount = card.unbilledItemsFlagged.length;

    return BlockScaffold(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                BlockIconButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                if (flagCount > 0)
                  ToneChip(
                    label: '$flagCount',
                    icon: Icons.flag_outlined,
                    tone: ChipTone.onBlock,
                    foreground: p.accent,
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.space8),
          Eyebrow(l10n.t(AppStrings.jobCardTitle), color: p.onBlockMuted),
          const SizedBox(height: AppTheme.space3),
          Text(
            // The vehicle is the headline: it is how a mechanic identifies the
            // job. The generic screen title moved up to the eyebrow.
            card.vehicleInfo.trim().isNotEmpty
                ? card.vehicleInfo.trim()
                : l10n.t(AppStrings.jobCardTitle),
            style: theme.textTheme.headlineMedium?.copyWith(color: p.onBlock),
          ),
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space5,
          AppTheme.space6,
          AppTheme.space5,
          AppTheme.space10,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (card.unbilledItemsFlagged.isNotEmpty) ...[
                  // Promoted to the top. This is the one thing on the screen
                  // that costs money if it is missed, and it used to sit below
                  // the fold under the parts table.
                  _FlagCard(items: card.unbilledItemsFlagged),
                  const SizedBox(height: AppTheme.space4),
                ],
                SurfaceCard(
                  padding: const EdgeInsets.all(AppTheme.space5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      JobCardFieldTile(
                        label: l10n.t(AppStrings.jobCardWorkPerformed),
                        value: card.workPerformed,
                      ),
                      JobCardFieldTile(
                        label: l10n.t(AppStrings.jobCardLaborTime),
                        // Shown as "1h 45m", not "1.75" — matching the printed
                        // job card, and the way the time was dictated.
                        value: formatLaborTime(card.laborHours),
                      ),
                      Text(
                        l10n.t(AppStrings.jobCardLaborRate).toUpperCase(),
                        style: theme.textTheme.labelSmall,
                      ),
                      const SizedBox(height: AppTheme.space2),
                      TextField(
                        controller: _laborRateController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
                        decoration: InputDecoration(
                          prefixText: '${currency.symbol} ',
                          hintText: 'e.g. 85.00',
                        ),
                      ),
                    ],
                  ),
                ),
                if (card.partsUsed.isNotEmpty) ...[
                  const SizedBox(height: AppTheme.space8),
                  SectionHeading(
                    title: l10n.t(AppStrings.jobCardPartsUsed),
                    trailing: ToneChip(
                      label: '${card.partsUsed.length}',
                      tone: ChipTone.neutral,
                    ),
                  ),
                  const SizedBox(height: AppTheme.space4),
                  SurfaceCard(
                    padding: const EdgeInsets.all(AppTheme.space5),
                    child: JobCardPartsEditTable(
                      partsUsed: card.partsUsed,
                      controllers: _partControllers,
                      currencySymbol: currency.symbol,
                    ),
                  ),
                ],
                const SizedBox(height: AppTheme.space10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _generating ? null : () => _saveAndGeneratePdf(currency),
                    icon: _generating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.picture_as_pdf_outlined, size: 19),
                    label: Text(l10n.t(AppStrings.jobCardSaveAndGeneratePdf)),
                  ),
                ),
                const SizedBox(height: AppTheme.space3),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _generating ? null : _tryAgain,
                    child: Text(l10n.t(AppStrings.jobCardTryAgain)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "worth double-checking" list.
///
/// Tinted with the accent rather than the error colour: nothing has gone
/// wrong, the app is flagging something for a human to confirm.
class _FlagCard extends StatelessWidget {
  const _FlagCard({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return SurfaceCard(
      color: p.accentSoft,
      padding: const EdgeInsets.all(AppTheme.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.flag_rounded, size: 18, color: p.accent),
              const SizedBox(width: AppTheme.space2),
              Expanded(
                child: Text(
                  l10n.t(AppStrings.jobCardUnbilledItems),
                  style: theme.textTheme.titleSmall?.copyWith(color: p.accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.space3),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.space2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7, right: AppTheme.space3),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      item,
                      style: theme.textTheme.bodyMedium?.copyWith(color: p.ink),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
