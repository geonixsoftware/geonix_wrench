import 'package:flutter/material.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../record/record_view.dart';
import '../settings/settings_view.dart';

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;

    // The block colour, not the canvas: each tab is a BlockScaffold whose top
    // is near-black, so anything showing through behind it should match
    // rather than flash white on a tab switch.
    return Scaffold(
      backgroundColor: p.block,
      body: Stack(
        children: [
          IndexedStack(
            index: _index,
            children: const [
              RecordView(),
              SettingsView(),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _FloatingNav(
              index: _index,
              onSelected: (index) => setState(() => _index = index),
              items: [
                _NavItem(
                  icon: Icons.mic_none_rounded,
                  activeIcon: Icons.mic_rounded,
                  label: l10n.t(AppStrings.navRecord),
                ),
                _NavItem(
                  icon: Icons.tune_rounded,
                  activeIcon: Icons.tune_rounded,
                  label: l10n.t(AppStrings.navSettings),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem {
  const _NavItem({required this.icon, required this.activeIcon, required this.label});

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// A floating pill nav rather than a full-width bar welded to the bottom edge.
///
/// Material's [NavigationBar] draws a 72px slab the exact width of the screen;
/// against a design built on rounded sheets it reads as a foreign component.
/// This detaches from the edge, so the sheet's own rounding stays visible
/// underneath it.
class _FloatingNav extends StatelessWidget {
  const _FloatingNav({
    required this.index,
    required this.onSelected,
    required this.items,
  });

  final int index;
  final ValueChanged<int> onSelected;
  final List<_NavItem> items;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppTheme.space6,
        0,
        AppTheme.space6,
        // Gesture-bar devices already reserve space; on a hardware-button
        // device the pill would otherwise sit flush on the bezel.
        bottomInset > 0 ? bottomInset : AppTheme.space5,
      ),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          boxShadow: AppTheme.shadowLifted(p),
        ),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: _NavButton(
                  item: items[i],
                  selected: i == index,
                  onTap: () => onSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item, required this.selected, required this.onTap});

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            height: 50,
            decoration: BoxDecoration(
              color: selected ? p.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(AppTheme.radiusPill),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? item.activeIcon : item.icon,
                  size: 21,
                  color: selected ? p.onAccent : p.inkTertiary,
                ),
                // The label only rides along on the selected pill. Two labels
                // permanently on show is what makes a two-tab bar look empty.
                if (selected) ...[
                  const SizedBox(width: AppTheme.space2),
                  Flexible(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.1,
                        color: p.onAccent,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
