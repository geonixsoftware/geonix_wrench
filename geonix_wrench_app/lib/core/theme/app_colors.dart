import 'package:flutter/material.dart';

/// One tonal palette per brightness.
///
/// The split is deliberate:
///
/// * **Backgrounds are neutral.** Canvas, surfaces, wells and the full-bleed
///   block are black / grey / white. Large areas carry no hue at all, so
///   nothing on this page competes with the content sitting on it.
/// * **Details carry the colour.** Headings, buttons, icon tiles, chips and
///   accents come from the "Mellow Espresso / Soft Ecru" ramp:
///
/// ```
///   #3B2A25  deep espresso   → headings
///   #6F4C3E  mellow espresso → icon tiles, the second voice
///   #BFAFA0  taupe           → muted detail on the dark block
///   #EAE1D6  soft ecru       → tinted detail fills
///   #C9531F  burnt orange    → accent, and nothing else
/// ```
@immutable
class AppPalette {
  const AppPalette({
    required this.canvas,
    required this.surface,
    required this.surfaceMuted,
    required this.surfaceSunken,
    required this.hairline,
    required this.ink,
    required this.inkSecondary,
    required this.inkTertiary,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.secondary,
    required this.secondarySoft,
    required this.onSecondary,
    required this.block,
    required this.blockRaised,
    required this.onBlock,
    required this.onBlockMuted,
    required this.success,
    required this.successSoft,
    required this.danger,
    required this.dangerSoft,
    required this.shadow,
  });

  /// Page background — the lowest layer. Neutral.
  final Color canvas;

  /// Cards and sheets sitting on the canvas. Neutral.
  final Color surface;

  /// Tonal blocks *inside* a card (totals, notes, steppers). Neutral.
  final Color surfaceMuted;

  /// Inset wells: text fields, track backgrounds. Neutral.
  final Color surfaceSunken;

  /// Reserved for genuine dividers between list rows. Deliberately close to
  /// the surface it sits on — it should be felt, not seen.
  final Color hairline;

  /// Headings and primary text. Deep espresso rather than pure black: at this
  /// value it still reads as black, but it belongs to the accent's family.
  final Color ink;

  /// Body and caption text. Neutral grey — running copy is a background
  /// element, not a detail.
  final Color inkSecondary;
  final Color inkTertiary;

  final Color accent;

  /// Accent at low saturation, for selected states and badges.
  final Color accentSoft;
  final Color onAccent;

  /// Mellow espresso. The second voice in the UI — icon tiles, informational
  /// chips, list-row glyphs — carried by a tone from the accent's family
  /// rather than by introducing a second hue.
  final Color secondary;
  final Color secondarySoft;
  final Color onSecondary;

  /// The near-black used for full-bleed blocks: the record hero, the auth top,
  /// the site header. Neutral, so the espresso and orange details sitting on
  /// it are the only colour in view.
  final Color block;

  /// One step up from [block], for anything sitting on top of it.
  final Color blockRaised;

  final Color onBlock;

  /// Taupe from the ramp — the one warm detail on the neutral block.
  final Color onBlockMuted;

  final Color success;
  final Color successSoft;
  final Color danger;
  final Color dangerSoft;

  final Color shadow;

  static const AppPalette light = AppPalette(
    canvas: Color(0xFFF6F6F6),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF0F0F0),
    surfaceSunken: Color(0xFFE8E8E8),
    hairline: Color(0xFFE0E0E0),
    ink: Color(0xFF3B2A25),
    inkSecondary: Color(0xFF5C5C5C),
    inkTertiary: Color(0xFF8C8C8C),
    accent: Color(0xFFC9531F),
    accentSoft: Color(0xFFF6E4D8),
    onAccent: Color(0xFFFFFFFF),
    secondary: Color(0xFF6F4C3E),
    secondarySoft: Color(0xFFEDE4DE),
    onSecondary: Color(0xFFFFFFFF),
    block: Color(0xFF1A1A1A),
    blockRaised: Color(0xFF262626),
    onBlock: Color(0xFFFAFAFA),
    onBlockMuted: Color(0xFFBFAFA0),
    success: Color(0xFF3E7A5C),
    successSoft: Color(0xFFE4EFE9),
    danger: Color(0xFFA83E2C),
    dangerSoft: Color(0xFFF7E5E1),
    shadow: Color(0x14000000),
  );

  /// Neutral greys taken down from the same axis. Only the accent, the
  /// espresso tiles and the taupe detail carry hue.
  static const AppPalette dark = AppPalette(
    canvas: Color(0xFF121212),
    surface: Color(0xFF1C1C1C),
    surfaceMuted: Color(0xFF262626),
    surfaceSunken: Color(0xFF303030),
    hairline: Color(0xFF343434),
    ink: Color(0xFFF5F3F1),
    inkSecondary: Color(0xFFABABAB),
    inkTertiary: Color(0xFF757575),
    accent: Color(0xFFE07E4A),
    accentSoft: Color(0xFF33231A),
    onAccent: Color(0xFF241209),
    secondary: Color(0xFFBFAFA0),
    secondarySoft: Color(0xFF2B2521),
    onSecondary: Color(0xFF121212),
    // Deeper than [canvas], so the sheet still reads as lifted *off* the
    // block rather than sinking into it.
    block: Color(0xFF000000),
    blockRaised: Color(0xFF1A1A1A),
    onBlock: Color(0xFFFAFAFA),
    onBlockMuted: Color(0xFFBFAFA0),
    success: Color(0xFF6BB58A),
    successSoft: Color(0xFF1B2A22),
    danger: Color(0xFFE08A76),
    dangerSoft: Color(0xFF2E1D1B),
    shadow: Color(0x66000000),
  );
}

/// Brightness-independent constants still referenced across the app.
class AppColors {
  AppColors._();

  static const Color accent = Color(0xFFC9531F);
  static const Color espresso = Color(0xFF6F4C3E);
  static const Color espressoDeep = Color(0xFF3B2A25);
  static const Color ecru = Color(0xFFEAE1D6);
  static const Color taupe = Color(0xFFBFAFA0);
  static const Color success = Color(0xFF3E7A5C);
  static const Color danger = Color(0xFFA83E2C);
}
