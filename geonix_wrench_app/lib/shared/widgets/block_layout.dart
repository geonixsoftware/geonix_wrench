import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';

/// The app's primary screen shape: a near-black block at the top, and the
/// content riding underneath it on a light sheet with a hard top radius.
///
/// This is the one structural idea the whole redesign hangs on. Every previous
/// screen was a flat canvas with cards floating on it, which gave no screen a
/// top, a focus, or a hierarchy — everything was the same distance from the
/// eye. Splitting the screen into *block* and *sheet* gives the headline
/// somewhere to live and lets the content start below it rather than compete
/// with it.
///
/// Note the block is [AppPalette.block] and never the accent: a full-bleed
/// saturated orange is precisely the high-contrast slab this design avoids.
class BlockScaffold extends StatelessWidget {
  const BlockScaffold({
    super.key,
    required this.header,
    required this.child,
    this.bottomBar,
    this.sheetColor,
    this.headerPadding = const EdgeInsets.fromLTRB(
      AppTheme.space6,
      AppTheme.space2,
      AppTheme.space6,
      AppTheme.space8,
    ),
  });

  /// Padding for a block that carries nothing but [AppHeaderBar] — the tab
  /// screens. The default leaves room under the header for a headline; without
  /// one, that room reads as a large empty band of near-black.
  static const EdgeInsets compactHeaderPadding = EdgeInsets.fromLTRB(
    AppTheme.space6,
    AppTheme.space2,
    AppTheme.space6,
    AppTheme.space5,
  );

  /// Content drawn on the dark block. Rendered with [AppPalette.onBlock]
  /// as the default ink, so callers do not have to recolour every child.
  final Widget header;

  /// Content on the light sheet.
  final Widget child;

  final Widget? bottomBar;
  final Color? sheetColor;
  final EdgeInsetsGeometry headerPadding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: p.block,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        // The block is dark in both themes, so the status bar icons must be
        // light in both. Left to the theme, light mode painted them dark on
        // near-black.
        value: isDark
            ? SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent)
            : SystemUiOverlayStyle.light.copyWith(
                statusBarColor: Colors.transparent,
                statusBarBrightness: Brightness.dark,
              ),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: headerPadding,
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: p.onBlock),
                  child: IconTheme.merge(
                    data: IconThemeData(color: p.onBlock),
                    child: header,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Container(
                width: double.infinity,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: sheetColor ?? p.canvas,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppTheme.radiusSheet),
                  ),
                ),
                child: child,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: bottomBar,
    );
  }
}

/// The standard header for a pushed sub-screen: back arrow, then the screen
/// title as a headline on the block.
///
/// Replaces the [AppBar] these screens used to carry. An AppBar puts the title
/// at 19px beside a 24px chevron; here the title is the largest thing on the
/// screen, which is what makes a pushed route feel like a destination rather
/// than a dialog.
class BlockTitleHeader extends StatelessWidget {
  const BlockTitleHeader({super.key, required this.title, this.eyebrow, this.trailing});

  final String title;
  final String? eyebrow;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              // Negative left inset so the 40px tap target's optical edge lines
              // up with the headline below it rather than sitting inside it.
              Transform.translate(
                offset: const Offset(-10, 0),
                child: IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                  color: p.onBlock,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                ),
              ),
              const Spacer(),
              ?trailing,
            ],
          ),
        ),
        const SizedBox(height: AppTheme.space6),
        if (eyebrow != null) ...[
          Eyebrow(eyebrow!, color: p.onBlockMuted),
          const SizedBox(height: AppTheme.space3),
        ],
        Text(
          title,
          style: theme.textTheme.displaySmall?.copyWith(color: p.onBlock),
        ),
      ],
    );
  }
}

/// Small uppercase label that sits above a headline.
///
/// The reference UIs all use one: it gives a heading a second line of
/// information without a second type size competing with it.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    );
  }
}

/// A rounded-square icon tile.
///
/// Lifted straight from the reference grids. Defaults to the espresso tone
/// rather than the accent, so a screen can show several without any of them
/// reading as the primary action.
class IconTile extends StatelessWidget {
  const IconTile(
    this.icon, {
    super.key,
    this.size = 46,
    this.tone = TileTone.secondary,
    this.onTap,
  });

  final IconData icon;
  final double size;
  final TileTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    final (Color background, Color foreground) = switch (tone) {
      TileTone.accent => (p.accentSoft, p.accent),
      TileTone.secondary => (p.secondarySoft, p.secondary),
      TileTone.neutral => (p.surfaceMuted, p.inkSecondary),
      TileTone.solid => (p.accent, p.onAccent),
    };

    final tile = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: Icon(icon, size: size * 0.46, color: foreground),
    );

    if (onTap == null) return tile;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(size * 0.34),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(size * 0.34),
        child: tile,
      ),
    );
  }
}

enum TileTone { accent, secondary, neutral, solid }

/// A tinted pill. Used for status, counts and metadata.
class ToneChip extends StatelessWidget {
  const ToneChip({
    super.key,
    required this.label,
    this.icon,
    this.dotColor,
    this.tone = ChipTone.neutral,
    this.background,
    this.foreground,
  });

  final String label;
  final IconData? icon;

  /// Draws a small filled dot before the label — the live/idle indicator.
  final Color? dotColor;

  final ChipTone tone;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    final (Color bg, Color fg) = switch (tone) {
      ChipTone.accent => (p.accentSoft, p.accent),
      ChipTone.secondary => (p.secondarySoft, p.secondary),
      ChipTone.success => (p.successSoft, p.success),
      ChipTone.danger => (p.dangerSoft, p.danger),
      ChipTone.neutral => (p.surfaceMuted, p.inkSecondary),
      ChipTone.onBlock => (Colors.white.withValues(alpha: 0.10), p.onBlock),
    };

    final resolvedBg = background ?? bg;
    final resolvedFg = foreground ?? fg;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: icon != null || dotColor != null ? AppTheme.space3 : AppTheme.space3 + 2,
        vertical: 7,
      ),
      decoration: BoxDecoration(
        color: resolvedBg,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppTheme.space2),
          ] else if (icon != null) ...[
            Icon(icon, size: 14, color: resolvedFg),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.05,
              color: resolvedFg,
            ),
          ),
        ],
      ),
    );
  }
}

enum ChipTone { accent, secondary, success, danger, neutral, onBlock }

/// Section label + optional trailing widget, for use on the light sheet.
class SectionHeading extends StatelessWidget {
  const SectionHeading({super.key, required this.title, this.trailing, this.eyebrow});

  final String title;
  final String? eyebrow;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (eyebrow != null) ...[
                Eyebrow(eyebrow!),
                const SizedBox(height: AppTheme.space2),
              ],
              Text(title, style: theme.textTheme.headlineSmall),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppTheme.space4),
          trailing!,
        ],
      ],
    );
  }
}
