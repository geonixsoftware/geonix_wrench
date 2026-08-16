import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The base panel used across the app.
///
/// It separates from the canvas by tone and a soft shadow rather than a drawn
/// border. The old version outlined every card in a 1px hairline, which stacked
/// up into a wireframe look once several sat on one screen.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = AppTheme.cardPadding,
    this.color,
    this.accented = false,
    this.radius = AppTheme.radiusLg,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  /// Highlights the card with a tinted accent edge — used sparingly, e.g. the
  /// recommended plan.
  final bool accented;

  final double radius;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shape = BorderRadius.circular(radius);

    final decoration = BoxDecoration(
      color: color ?? p.surface,
      borderRadius: shape,
      boxShadow: AppTheme.shadowSoft(p),
      border: accented ? Border.all(color: p.accent.withValues(alpha: 0.35), width: 1.5) : null,
    );

    final content = Padding(padding: padding, child: child);

    if (onTap == null) {
      return Container(
        width: double.infinity,
        decoration: decoration,
        child: content,
      );
    }

    return DecoratedBox(
      decoration: decoration,
      child: Material(
        color: Colors.transparent,
        borderRadius: shape,
        child: InkWell(
          onTap: onTap,
          borderRadius: shape,
          child: SizedBox(width: double.infinity, child: content),
        ),
      ),
    );
  }
}

/// A tonal block used *inside* a [SurfaceCard] — totals, notes, steppers.
/// One level up from the card so nested content never needs an outline.
class SurfaceWell extends StatelessWidget {
  const SurfaceWell({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppTheme.space4,
      vertical: AppTheme.space3,
    ),
    this.color,
    this.radius = AppTheme.radiusMd,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? context.palette.surfaceMuted,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}
