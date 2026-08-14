import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppTheme {
  AppTheme._();

  static const double radius = 16;
  static const double buttonRadius = 12;
  static const double dialogRadius = 16;
  static const double recordButtonRadius = 24;
  static const EdgeInsets cardPadding = EdgeInsets.all(20);
  static const EdgeInsets screenPadding = EdgeInsets.all(20);

  static ThemeData light = _build(
    brightness: Brightness.light,
    canvas: AppColors.canvasLight,
    surface: AppColors.surfaceLight,
    surfaceElevated: AppColors.surfaceElevatedLight,
    border: AppColors.borderLight,
    text: AppColors.textLight,
  );

  static ThemeData dark = _build(
    brightness: Brightness.dark,
    canvas: AppColors.canvasDark,
    surface: AppColors.surfaceDark,
    surfaceElevated: AppColors.surfaceElevatedDark,
    border: AppColors.borderDark,
    text: AppColors.textDark,
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color canvas,
    required Color surface,
    required Color surfaceElevated,
    required Color border,
    required Color text,
  }) {
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: AppColors.accent,
      onPrimary: Colors.white,
      secondary: AppColors.accent,
      onSecondary: Colors.white,
      error: AppColors.danger,
      onError: Colors.white,
      surface: surface,
      onSurface: text,
      surfaceContainerHighest: surfaceElevated,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      fontFamily: 'Roboto',
      dividerColor: border,
      splashFactory: InkRipple.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: text,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: border, width: AppColors.borderWidth),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(dialogRadius),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: border, width: AppColors.borderWidth),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: text,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: border, width: AppColors.borderWidth),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: border, width: AppColors.borderWidth),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: text,
        textColor: text,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.accent.withValues(alpha: 0.10),
        elevation: 0,
      ),
      textTheme: Typography.material2021(platform: TargetPlatform.iOS)
          .black
          .apply(bodyColor: text, displayColor: text),
      colorSchemeSeed: null,
    ).copyWith(
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
            bodyColor: text,
            displayColor: text,
          ),
    );
  }
}
