import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/models/job_card.dart';

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
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < partsUsed.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(height: 16),
            Divider(color: theme.dividerColor, height: 1),
            const SizedBox(height: 16),
          ],
          Text(
            partsUsed[i].partName,
            style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
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
              const SizedBox(width: 12),
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
