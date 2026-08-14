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
import '../../shared/widgets/surface_card.dart';
import 'widgets/job_card_field_tile.dart';
import 'widgets/job_card_parts_table.dart';

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
    _pdfService = PdfService(authService: authService);
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
      await _pdfService.generate(editedCard, currency);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t(AppStrings.jobCardPdfSaved))),
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
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final currency = context.watch<AppSettings>().currency;
    final card = widget.jobCard;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t(AppStrings.jobCardTitle))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    JobCardFieldTile(
                      label: l10n.t(AppStrings.jobCardVehicleInfo),
                      value: card.vehicleInfo,
                    ),
                    JobCardFieldTile(
                      label: l10n.t(AppStrings.jobCardLaborHours),
                      value: card.laborHours.toStringAsFixed(2),
                    ),
                    JobCardFieldTile(
                      label: l10n.t(AppStrings.jobCardWorkPerformed),
                      value: card.workPerformed,
                    ),
                    Text(
                      l10n.t(AppStrings.jobCardLaborRate),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 4),
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
                const SizedBox(height: 20),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.t(AppStrings.jobCardPartsUsed), style: theme.textTheme.titleMedium),
                      const SizedBox(height: 16),
                      JobCardPartsEditTable(
                        partsUsed: card.partsUsed,
                        controllers: _partControllers,
                        currencySymbol: currency.symbol,
                      ),
                    ],
                  ),
                ),
              ],
              if (card.unbilledItemsFlagged.isNotEmpty) ...[
                const SizedBox(height: 20),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.t(AppStrings.jobCardUnbilledItems),
                        style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.error),
                      ),
                      const SizedBox(height: 12),
                      for (final item in card.unbilledItemsFlagged)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('•  $item'),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _generating ? null : () => _saveAndGeneratePdf(currency),
                  child: _generating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(l10n.t(AppStrings.jobCardSaveAndGeneratePdf)),
                ),
              ),
              const SizedBox(height: 12),
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
    );
  }
}
