import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_service.dart';
import '../../core/billing/billing_controller.dart';
import '../../core/billing/billing_gate.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/services/shop_logo_service.dart';
import '../../core/settings/app_settings.dart';
import '../../shared/widgets/surface_card.dart';
import '../auth/organization_screen.dart';
import '../billing/billing_screen.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = context.watch<AppSettings>();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SettingsSection(
              title: l10n.t(AppStrings.settingsAppearance),
              child: SegmentedButton<AppThemeMode>(
                segments: [
                  ButtonSegment(
                    value: AppThemeMode.dark,
                    label: Text(l10n.t(AppStrings.settingsThemeDark)),
                    icon: const Icon(Icons.dark_mode_outlined),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.light,
                    label: Text(l10n.t(AppStrings.settingsThemeLight)),
                    icon: const Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.system,
                    label: Text(l10n.t(AppStrings.settingsThemeSystem)),
                    icon: const Icon(Icons.smartphone_outlined),
                  ),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (selection) => settings.setThemeMode(selection.first),
              ),
            ),
            const SizedBox(height: 20),
            _SettingsSection(
              title: l10n.t(AppStrings.settingsLanguage),
              child: DropdownButtonFormField<AppLanguage>(
                initialValue: settings.language,
                items: [
                  for (final language in AppLanguage.values)
                    DropdownMenuItem(value: language, child: Text(language.nativeName)),
                ],
                onChanged: (language) {
                  if (language != null) settings.setLanguage(language);
                },
              ),
            ),
            const SizedBox(height: 20),
            _SettingsSection(
              title: l10n.t(AppStrings.settingsCurrency),
              child: DropdownButtonFormField<AppCurrency>(
                initialValue: settings.currency,
                items: [
                  for (final currency in AppCurrency.values)
                    DropdownMenuItem(
                      value: currency,
                      child: Text('${currency.code} (${currency.symbol})'),
                    ),
                ],
                onChanged: (currency) {
                  if (currency != null) settings.setCurrency(currency);
                },
              ),
            ),
            const SizedBox(height: 20),
            const _ShopLogoSection(),
            const SizedBox(height: 20),
            _SettingsSection(
              title: l10n.t(AppStrings.settingsOrganization),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.t(AppStrings.settingsOrganizationDescription),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(builder: (_) => const OrganizationScreen()),
                    ),
                    icon: const Icon(Icons.groups_outlined),
                    label: Text(l10n.t(AppStrings.settingsOrganizationManage)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _SettingsSection(
              title: l10n.t(AppStrings.settingsSubscription),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.t(AppStrings.settingsSubscriptionDescription),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(builder: (_) => const BillingScreen()),
                    ),
                    icon: const Icon(Icons.workspace_premium_outlined),
                    label: Text(l10n.t(AppStrings.settingsSubscriptionManage)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShopLogoSection extends StatefulWidget {
  const _ShopLogoSection();

  @override
  State<_ShopLogoSection> createState() => _ShopLogoSectionState();
}

class _ShopLogoSectionState extends State<_ShopLogoSection> {
  late final ShopLogoService _service;
  bool _loading = true;
  bool _busy = false;
  bool _hasCustomLogo = false;
  Uint8List? _logoBytes;

  @override
  void initState() {
    super.initState();
    _service = ShopLogoService(authService: context.read<AuthService>());
    _load();
  }

  Future<void> _load() async {
    try {
      final hasCustomLogo = await _service.fetchStatus();
      final bytes = await _service.fetchLogoBytes();
      if (!mounted) return;
      setState(() {
        _hasCustomLogo = hasCustomLogo;
        _logoBytes = bytes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _pickAndUpload() async {
    if (!context.read<BillingController>().isActive) {
      await showSubscriptionRequiredDialog(context);
      return;
    }

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    setState(() => _busy = true);
    try {
      final bytes = await picked.readAsBytes();
      await _service.uploadLogo(bytes, picked.name);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.t(AppStrings.settingsShopLogoUploadError))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (!context.read<BillingController>().isActive) {
      await showSubscriptionRequiredDialog(context);
      return;
    }

    setState(() => _busy = true);
    try {
      await _service.deleteLogo();
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.t(AppStrings.settingsShopLogoRemoveError))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final subscriptionActive = context.watch<BillingController>().isActive;

    return _SettingsSection(
      title: l10n.t(AppStrings.settingsShopLogo),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.t(AppStrings.settingsShopLogoDescription),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator(strokeWidth: 2))
          else ...[
            Container(
              height: 80,
              width: double.infinity,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _logoBytes != null
                  ? Image.memory(_logoBytes!, fit: BoxFit.contain, height: 56)
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
            if (!_hasCustomLogo)
              Text(
                l10n.t(AppStrings.settingsShopLogoDefaultLabel),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _pickAndUpload,
                  style: subscriptionActive
                      ? null
                      : FilledButton.styleFrom(
                          foregroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                          backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        ),
                  icon: const Icon(Icons.upload_outlined),
                  label: Text(l10n.t(AppStrings.settingsShopLogoUpload)),
                ),
                if (_hasCustomLogo) ...[
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: _busy ? null : _remove,
                    style: subscriptionActive
                        ? null
                        : TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                          ),
                    icon: const Icon(Icons.delete_outline),
                    label: Text(l10n.t(AppStrings.settingsShopLogoRemove)),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}
