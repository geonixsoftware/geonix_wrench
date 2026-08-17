import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

enum AppThemeMode { dark, light, system }

enum AppLanguage {
  english,
  czech,
  polish,
  german,
  spanish,
  french,
  italian,
  dutch,
  swedish,
  finnish,
}

extension AppLanguageCode on AppLanguage {
  String get code {
    switch (this) {
      case AppLanguage.english:
        return 'en';
      case AppLanguage.czech:
        return 'cs';
      case AppLanguage.polish:
        return 'pl';
      case AppLanguage.german:
        return 'de';
      case AppLanguage.spanish:
        return 'es';
      case AppLanguage.french:
        return 'fr';
      case AppLanguage.italian:
        return 'it';
      case AppLanguage.dutch:
        return 'nl';
      case AppLanguage.swedish:
        return 'sv';
      case AppLanguage.finnish:
        return 'fi';
    }
  }

  String get nativeName {
    switch (this) {
      case AppLanguage.english:
        return 'English';
      case AppLanguage.czech:
        return 'Čeština';
      case AppLanguage.polish:
        return 'Polski';
      case AppLanguage.german:
        return 'Deutsch';
      case AppLanguage.spanish:
        return 'Español';
      case AppLanguage.french:
        return 'Français';
      case AppLanguage.italian:
        return 'Italiano';
      case AppLanguage.dutch:
        return 'Nederlands';
      case AppLanguage.swedish:
        return 'Svenska';
      case AppLanguage.finnish:
        return 'Suomi';
    }
  }

  Locale get locale => Locale(code);

  static AppLanguage fromCode(String code) {
    return AppLanguage.values.firstWhere(
      (language) => language.code == code,
      orElse: () => AppLanguage.english,
    );
  }
}

enum AppCurrency { eur, czk, pln, gbp, chf, sek, nok, dkk, huf, ron }

extension AppCurrencyDetails on AppCurrency {
  String get code {
    switch (this) {
      case AppCurrency.eur:
        return 'EUR';
      case AppCurrency.czk:
        return 'CZK';
      case AppCurrency.pln:
        return 'PLN';
      case AppCurrency.gbp:
        return 'GBP';
      case AppCurrency.chf:
        return 'CHF';
      case AppCurrency.sek:
        return 'SEK';
      case AppCurrency.nok:
        return 'NOK';
      case AppCurrency.dkk:
        return 'DKK';
      case AppCurrency.huf:
        return 'HUF';
      case AppCurrency.ron:
        return 'RON';
    }
  }

  String get symbol {
    switch (this) {
      case AppCurrency.eur:
        return '€';
      case AppCurrency.czk:
        return 'Kč';
      case AppCurrency.pln:
        return 'zł';
      case AppCurrency.gbp:
        return '£';
      case AppCurrency.chf:
        return 'Fr';
      case AppCurrency.sek:
        return 'kr';
      case AppCurrency.nok:
        return 'kr';
      case AppCurrency.dkk:
        return 'kr';
      case AppCurrency.huf:
        return 'Ft';
      case AppCurrency.ron:
        return 'lei';
    }
  }

  static AppCurrency fromCode(String code) {
    return AppCurrency.values.firstWhere(
      (currency) => currency.code == code,
      orElse: () => AppCurrency.eur,
    );
  }
}

class AppSettings extends ChangeNotifier {
  static const _themeKey = 'settings.theme_mode';
  static const _languageKey = 'settings.language';
  static const _currencyKey = 'settings.currency';
  static const _pdfDirectoryKey = 'settings.pdf_directory';
  static const _apiBaseUrlKey = 'settings.api_base_url';

  AppThemeMode _themeMode = AppThemeMode.system;
  AppLanguage _language = AppLanguage.english;
  AppCurrency _currency = AppCurrency.eur;
  String? _pdfDirectory;
  String? _apiBaseUrlOverride;
  bool _loaded = false;

  AppThemeMode get themeMode => _themeMode;
  AppLanguage get language => _language;
  AppCurrency get currency => _currency;
  bool get isLoaded => _loaded;

  /// Where generated job-card PDFs are written. `null` means "wherever the
  /// platform puts downloads" — resolved at save time rather than stored, so
  /// the default keeps working if the OS moves the folder.
  String? get pdfDirectory => _pdfDirectory;

  /// Backend address typed into Settings, or null to use the compiled-in one.
  ///
  /// Read and honoured in debug builds only — see [apiBaseUrl]. It is still
  /// stored and returned here in release builds so the value survives a switch
  /// between build modes, but nothing acts on it there.
  String? get apiBaseUrlOverride => _apiBaseUrlOverride;

  /// The address actually in use, whatever its source. Shown in Settings so the
  /// answer to "which server am I talking to" is never a guess.
  String get effectiveApiBaseUrl => apiBaseUrl();

  ThemeMode get flutterThemeMode {
    switch (_themeMode) {
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final themeName = prefs.getString(_themeKey);
    final languageCode = prefs.getString(_languageKey);
    final currencyCode = prefs.getString(_currencyKey);

    if (themeName != null) {
      _themeMode = AppThemeMode.values.firstWhere(
        (mode) => mode.name == themeName,
        orElse: () => AppThemeMode.system,
      );
    }
    if (languageCode != null) {
      _language = AppLanguageCode.fromCode(languageCode);
    }
    if (currencyCode != null) {
      _currency = AppCurrencyDetails.fromCode(currencyCode);
    }
    _pdfDirectory = prefs.getString(_pdfDirectoryKey);

    // Pushed into app_config before anything can issue a request, so the first
    // call of the session already goes to the chosen server rather than the
    // compiled-in one.
    _apiBaseUrlOverride = normalizeApiBaseUrl(prefs.getString(_apiBaseUrlKey));
    setRuntimeApiBaseUrl(_apiBaseUrlOverride);

    _loaded = true;
    notifyListeners();
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
  }

  Future<void> setLanguage(AppLanguage language) async {
    _language = language;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, language.code);
  }

  Future<void> setCurrency(AppCurrency currency) async {
    _currency = currency;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_currencyKey, currency.code);
  }

  /// Points the app at a different backend. Pass `null` to go back to the
  /// address compiled into the build.
  ///
  /// Returns false if the text is not a usable http/https address, so the
  /// caller can say so rather than silently storing something unreachable.
  Future<bool> setApiBaseUrlOverride(String? url) async {
    final trimmed = url?.trim();
    final normalized = normalizeApiBaseUrl(trimmed);
    final clearing = trimmed == null || trimmed.isEmpty;
    if (!clearing && normalized == null) return false;

    _apiBaseUrlOverride = normalized;
    setRuntimeApiBaseUrl(normalized);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    if (normalized == null) {
      await prefs.remove(_apiBaseUrlKey);
    } else {
      await prefs.setString(_apiBaseUrlKey, normalized);
    }
    return true;
  }

  /// Pass `null` to go back to the platform's downloads folder.
  Future<void> setPdfDirectory(String? path) async {
    _pdfDirectory = path;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove(_pdfDirectoryKey);
    } else {
      await prefs.setString(_pdfDirectoryKey, path);
    }
  }
}
