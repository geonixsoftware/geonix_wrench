import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Makes the tonal palette reachable from any widget via
/// `Theme.of(context).extension<AppSurfaces>()!` — or the [AppSurfacesX]
/// shorthand below.
@immutable
class AppSurfaces extends ThemeExtension<AppSurfaces> {
  const AppSurfaces(this.palette);

  final AppPalette palette;

  @override
  AppSurfaces copyWith({AppPalette? palette}) => AppSurfaces(palette ?? this.palette);

  // The palette is a fixed pair of constants that swap wholesale at the theme
  // boundary, so there is nothing meaningful to interpolate between.
  @override
  AppSurfaces lerp(ThemeExtension<AppSurfaces>? other, double t) =>
      t < 0.5 ? this : (other as AppSurfaces? ?? this);
}

extension AppSurfacesX on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppSurfaces>()!.palette;
}

class AppTheme {
  AppTheme._();

  // ------------------------------------------------------------- geometry
  //
  // A softer, larger rounding scale than the previous 10/14/20/26. The
  // reference UIs all round hard — sheets at ~28px, controls fully pilled —
  // and a timid radius is most of what separates a designed screen from a
  // default one. Controls are pills; containers use the scale.

  static const double radiusSm = 12;
  static const double radiusMd = 18;
  static const double radiusLg = 24;
  static const double radiusXl = 32;

  /// The overlap radius where a light sheet meets a dark block.
  static const double radiusSheet = 34;
  static const double radiusPill = 999;

  /// Retained for existing call sites.
  static const double radius = radiusLg;
  static const double buttonRadius = radiusPill;
  static const double dialogRadius = radiusXl;
  static const double recordButtonRadius = radiusXl;

  // -------------------------------------------------------------- spacing
  //
  // 4-point scale. Screens should use these rather than ad-hoc numbers.

  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 20;
  static const double space6 = 24;
  static const double space8 = 32;
  static const double space10 = 40;
  static const double space12 = 56;

  static const EdgeInsets cardPadding = EdgeInsets.all(space5);
  static const EdgeInsets screenPadding = EdgeInsets.all(space5);

  /// Widest a single column of content should ever get. Full-width text on a
  /// desktop window was one of the layout problems.
  static const double contentMaxWidth = 560;

  /// Bottom room a tab's scroll view must leave clear for the floating nav
  /// pill, which is drawn over the content rather than beside it.
  static const double navClearance = 104;

  // ------------------------------------------------------------ elevation
  //
  // Two stacked layers: a near-invisible contact shadow and a broad ambient
  // one. Nothing casts a hard drop.

  static List<BoxShadow> shadowSoft(AppPalette p) => [
        BoxShadow(color: p.shadow, blurRadius: 2, offset: const Offset(0, 1)),
        BoxShadow(
          color: p.shadow,
          blurRadius: 24,
          spreadRadius: -8,
          offset: const Offset(0, 8),
        ),
      ];

  /// For a sheet that overlaps a dark block — it needs to lift further than a
  /// card sitting flat on the canvas.
  static List<BoxShadow> shadowLifted(AppPalette p) => [
        BoxShadow(color: p.shadow, blurRadius: 4, offset: const Offset(0, 2)),
        BoxShadow(
          color: p.shadow,
          blurRadius: 48,
          spreadRadius: -16,
          offset: const Offset(0, 20),
        ),
      ];

  // --------------------------------------------------------------- themes

  static final ThemeData light = _build(Brightness.light, AppPalette.light);
  static final ThemeData dark = _build(Brightness.dark, AppPalette.dark);

  static ThemeData _build(Brightness brightness, AppPalette p) {
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: p.accent,
      onPrimary: p.onAccent,
      primaryContainer: p.accentSoft,
      onPrimaryContainer: p.accent,
      secondary: p.secondary,
      onSecondary: p.onSecondary,
      secondaryContainer: p.secondarySoft,
      onSecondaryContainer: p.secondary,
      tertiary: p.secondary,
      onTertiary: p.onSecondary,
      error: p.danger,
      onError: brightness == Brightness.light ? Colors.white : const Color(0xFF2B1512),
      errorContainer: p.dangerSoft,
      onErrorContainer: p.danger,
      surface: p.surface,
      onSurface: p.ink,
      onSurfaceVariant: p.inkSecondary,
      surfaceContainerLowest: p.canvas,
      surfaceContainerLow: p.surface,
      surfaceContainer: p.surfaceMuted,
      surfaceContainerHigh: p.surfaceMuted,
      surfaceContainerHighest: p.surfaceSunken,
      inverseSurface: p.block,
      onInverseSurface: p.onBlock,
      outline: p.hairline,
      outlineVariant: p.hairline,
      shadow: p.shadow,
    );

    final text = _textTheme(brightness, p);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.canvas,
      canvasColor: p.canvas,
      // No hardcoded family: this used to pin 'Roboto', which overrode the
      // native face on Apple platforms and is a big part of the generic look.
      dividerColor: p.hairline,
      splashFactory: InkSparkle.splashFactory,
      extensions: [AppSurfaces(p)],
      textTheme: text,

      appBarTheme: AppBarTheme(
        backgroundColor: p.canvas,
        foregroundColor: p.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),

      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLg)),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium?.copyWith(color: p.inkSecondary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusXl)),
        insetPadding: const EdgeInsets.symmetric(horizontal: space6, vertical: space6),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusSheet)),
        ),
      ),

      // Pill CTAs. Every reference UI does this and it is the single loudest
      // signal that a screen was designed rather than assembled.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          disabledBackgroundColor: p.surfaceSunken,
          disabledForegroundColor: p.inkTertiary,
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: space8),
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
          ),
          shape: const StadiumBorder(),
        ),
      ),

      // ElevatedButton is styled to match FilledButton so the two never look
      // like different components when they appear on the same screen.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          disabledBackgroundColor: p.surfaceSunken,
          disabledForegroundColor: p.inkTertiary,
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: space8),
          elevation: 0,
          shadowColor: Colors.transparent,
          textStyle: const TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
          ),
          shape: const StadiumBorder(),
        ),
      ),

      // A tonal fill rather than an outline — same reason the cards lost theirs.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.ink,
          backgroundColor: p.surfaceMuted,
          side: BorderSide.none,
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: space8),
          textStyle: const TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
          ),
          shape: const StadiumBorder(),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accent,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: space4, vertical: space2),
          textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          shape: const StadiumBorder(),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: p.ink,
          highlightColor: p.surfaceMuted,
          shape: const CircleBorder(),
        ),
      ),

      // Filled wells with no resting outline; the border only appears on focus.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: space5, vertical: space4),
        hintStyle: TextStyle(color: p.inkTertiary),
        labelStyle: TextStyle(color: p.inkSecondary),
        floatingLabelStyle: TextStyle(color: p.accent, fontWeight: FontWeight.w700),
        prefixIconColor: p.inkTertiary,
        suffixIconColor: p.inkTertiary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: p.accent, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: p.danger, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: p.danger, width: 1.6),
        ),
      ),

      listTileTheme: ListTileThemeData(
        iconColor: p.inkSecondary,
        textColor: p.ink,
        contentPadding: const EdgeInsets.symmetric(horizontal: space4, vertical: space1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
      ),

      // The root shell draws its own floating pill nav; this keeps any stray
      // NavigationBar consistent with it.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.accentSoft,
        indicatorShape: const StadiumBorder(),
        elevation: 0,
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 23,
            color: states.contains(WidgetState.selected) ? p.accent : p.inkTertiary,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? p.accent : p.inkTertiary,
          ),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.block,
        contentTextStyle: TextStyle(color: p.onBlock, fontSize: 14),
        actionTextColor: p.accent,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        insetPadding: const EdgeInsets.all(space4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
      ),

      dividerTheme: DividerThemeData(color: p.hairline, thickness: 1, space: 1),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.surfaceSunken,
        circularTrackColor: Colors.transparent,
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: p.surfaceMuted,
          foregroundColor: p.inkSecondary,
          // Accent tint, not a surface tone. `surface` reads as "raised" in
          // light mode but is *darker* than surfaceMuted in dark mode, so the
          // selected segment rendered recessed — the opposite of selected.
          // The accent tint is unambiguous in both.
          selectedBackgroundColor: p.accentSoft,
          selectedForegroundColor: p.accent,
          side: BorderSide.none,
          padding: const EdgeInsets.symmetric(horizontal: space5, vertical: space3),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          shape: const StadiumBorder(),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceMuted,
        selectedColor: p.accentSoft,
        labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: space3, vertical: space2),
        shape: const StadiumBorder(),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: p.block,
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        textStyle: TextStyle(color: p.onBlock, fontSize: 12.5),
        padding: const EdgeInsets.symmetric(horizontal: space3, vertical: space2),
      ),
    );
  }

  /// A deliberate scale: heavy, tightly-tracked headings against comfortable
  /// body copy. The reference UIs all lead with a headline that is genuinely
  /// large — the previous scale topped out at 34/w700, which reads as a label.
  static TextTheme _textTheme(Brightness brightness, AppPalette p) {
    final base = ThemeData(brightness: brightness).textTheme;

    TextStyle? h(TextStyle? s, double size, FontWeight w, double tracking) => s?.copyWith(
          fontSize: size,
          fontWeight: w,
          letterSpacing: tracking,
          color: p.ink,
          height: 1.1,
        );

    TextStyle? body(TextStyle? s, double size, {Color? color, FontWeight? w}) =>
        s?.copyWith(fontSize: size, color: color ?? p.ink, height: 1.5, fontWeight: w);

    return base.copyWith(
      displayLarge: h(base.displayLarge, 46, FontWeight.w800, -1.6),
      displayMedium: h(base.displayMedium, 40, FontWeight.w800, -1.3),
      displaySmall: h(base.displaySmall, 34, FontWeight.w800, -1.0),
      headlineMedium: h(base.headlineMedium, 28, FontWeight.w800, -0.7),
      headlineSmall: h(base.headlineSmall, 23, FontWeight.w700, -0.45),
      titleLarge: h(base.titleLarge, 19, FontWeight.w700, -0.3),
      titleMedium: h(base.titleMedium, 16, FontWeight.w700, -0.15),
      titleSmall: h(base.titleSmall, 14.5, FontWeight.w600, 0),
      bodyLarge: body(base.bodyLarge, 16),
      bodyMedium: body(base.bodyMedium, 14.5, color: p.inkSecondary),
      bodySmall: body(base.bodySmall, 13, color: p.inkSecondary),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: 14.5,
        fontWeight: FontWeight.w700,
        color: p.ink,
        letterSpacing: 0,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: p.inkSecondary,
        letterSpacing: 0,
      ),
      // The one place tracking opens up: the small uppercase eyebrow used
      // above section headings and on field labels.
      labelSmall: base.labelSmall?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        color: p.inkTertiary,
        letterSpacing: 0.9,
      ),
    );
  }
}
