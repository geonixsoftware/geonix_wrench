import 'package:flutter/material.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../shared/widgets/app_header.dart';
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

    return Scaffold(
      appBar: const AppHeader(),
      body: IndexedStack(
        index: _index,
        children: const [
          RecordView(),
          SettingsView(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.mic_none_rounded),
            selectedIcon: const Icon(Icons.mic_rounded),
            label: l10n.t(AppStrings.navRecord),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings_rounded),
            label: l10n.t(AppStrings.navSettings),
          ),
        ],
      ),
    );
  }
}
