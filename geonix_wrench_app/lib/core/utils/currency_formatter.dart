import '../settings/app_settings.dart';

class CurrencyFormatter {
  CurrencyFormatter(this.currency);

  final AppCurrency currency;

  static const _symbolBeforeAmount = {
    AppCurrency.eur,
    AppCurrency.gbp,
  };

  String format(double amount) {
    final formatted = amount.toStringAsFixed(2);
    if (_symbolBeforeAmount.contains(currency)) {
      return '${currency.symbol}$formatted';
    }
    return '$formatted ${currency.symbol}';
  }
}
