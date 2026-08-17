import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'geonix_logo.dart';

/// The brand row that sits at the top of the dark block.
///
/// Previously this was an [AppBar] on a light canvas, which meant the app
/// opened onto a hairline-separated bar indistinguishable from any Material
/// default. It now lives *inside* [BlockScaffold]'s header, so it renders on
/// the dark block and is a plain row rather than a [PreferredSizeWidget] —
/// [BlockScaffold] already owns the safe-area inset the old version
/// mis-measured.
class AppHeaderBar extends StatelessWidget {
  const AppHeaderBar({super.key, this.label, this.actions});

  /// Caption printed immediately after the wordmark, behind a hairline rule —
  /// the date on the record screen, the screen name elsewhere.
  ///
  /// This is where a screen's second line of information goes now. It used to
  /// be a 34px headline stacked *under* this bar, which cost roughly a third of
  /// the block's height to say "Ready to record" — something the record control
  /// below already says by existing.
  final String? label;

  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);

    return SizedBox(
      height: 40,
      child: Row(
        children: [
          const GeonixLogo(height: 34, onDark: true),
          if (label != null) ...[
            const SizedBox(width: AppTheme.space3),
            Container(
              width: 1,
              height: 18,
              color: p.onBlockMuted.withValues(alpha: 0.35),
            ),
            const SizedBox(width: AppTheme.space3),
            Expanded(
              child: Text(
                label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontSize: 13,
                  color: p.onBlockMuted,
                ),
              ),
            ),
          ] else
            const Spacer(),
          if (actions != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final action in actions!) ...[
                  action,
                  const SizedBox(width: AppTheme.space1),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

/// A circular translucent icon button for use on the dark block.
class BlockIconButton extends StatelessWidget {
  const BlockIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        iconSize: 20,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(foregroundColor: p.onBlock),
        icon: Icon(icon),
      ),
    );
  }
}
