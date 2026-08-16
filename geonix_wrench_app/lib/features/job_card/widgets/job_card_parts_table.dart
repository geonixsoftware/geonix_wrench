import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/models/job_card.dart';
import '../../../core/theme/app_theme.dart';

class PartEditControllers {
  PartEditControllers(PartUsed part)
      : quantityController = TextEditingController(text: part.quantity.toString()),
        unitPriceController = TextEditingController(
          text: part.unitPrice != null ? part.unitPrice!.toStringAsFixed(2) : '',
        );

  final TextEditingController quantityController;
  final TextEditingController unitPriceController;

  void dispose() {
    quantityController.dispose();
    unitPriceController.dispose();
  }
}

class JobCardPartsEditTable extends StatelessWidget {
  const JobCardPartsEditTable({
    super.key,
    required this.partsUsed,
    required this.controllers,
    required this.currencySymbol,
  });

  final List<PartUsed> partsUsed;
  final List<PartEditControllers> controllers;
  final String currencySymbol;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < partsUsed.length; i++) ...[
          // Numbered rows rather than divider-separated blocks: with two text
          // fields per part, a 1px rule was not enough to tell where one part
          // ended and the next began.
          if (i > 0) const SizedBox(height: AppTheme.space5),
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.secondarySoft,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  '${i + 1}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: p.secondary,
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.space3),
              Expanded(
                child: Text(
                  partsUsed[i].partName,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.space3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: controllers[i].quantityController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(labelText: l10n.t(AppStrings.jobCardQuantity)),
                ),
              ),
              const SizedBox(width: AppTheme.space3),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: controllers[i].unitPriceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
                  decoration: InputDecoration(
                    labelText: l10n.t(AppStrings.jobCardUnitPrice),
                    prefixText: '$currencySymbol ',
                    hintText: 'TBD',
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
