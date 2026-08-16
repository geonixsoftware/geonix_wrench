import 'package:intl/intl.dart';

import '../settings/app_settings.dart';

class CurrencyFormatter {
  CurrencyFormatter(this.currency, {String? locale})
      : _number = NumberFormat('#,##0.00', locale);

  final AppCurrency currency;

  /// Grouped thousands. A shop with a large parts bill (or a large seat count)
  /// otherwise reads "26973.00", which is hard to scan at a glance.
  final NumberFormat _number;

  static const _symbolBeforeAmount = {
    AppCurrency.eur,
    AppCurrency.gbp,
  };

  String format(double amount) {
    final formatted = _number.format(amount);
    if (_symbolBeforeAmount.contains(currency)) {
      return '${currency.symbol}$formatted';
    }
    return '$formatted ${currency.symbol}';
  }
}
