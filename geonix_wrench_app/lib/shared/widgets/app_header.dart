import 'package:flutter/material.dart';

import 'geonix_logo.dart';

class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  const AppHeader({super.key, this.actions});

  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).dividerColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      height: preferredSize.height,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: border, width: 1)),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            const GeonixLogo(height: 28),
            const Spacer(),
            ...?actions,
          ],
        ),
      ),
    );
  }
}
