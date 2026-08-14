import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A rounded surface with a faint background contrast and a subtle border,
/// used as the base building block for card-based layouts across the app.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = AppTheme.cardPadding,
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? theme.cardTheme.color,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: borderColor ?? theme.dividerColor),
      ),
      child: child,
    );
  }
}
