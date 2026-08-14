import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/app_strings.dart';
import '../../features/billing/billing_screen.dart';

Future<void> showSubscriptionRequiredDialog(BuildContext context) {
  final l10n = context.l10n;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.t(AppStrings.billingBlockedDialogTitle)),
      content: Text(l10n.t(AppStrings.billingBlockedDialogMessage)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.t(AppStrings.cancel)),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const BillingScreen()),
            );
          },
          child: Text(l10n.t(AppStrings.billingBlockedDialogAction)),
        ),
      ],
    ),
  );
}
