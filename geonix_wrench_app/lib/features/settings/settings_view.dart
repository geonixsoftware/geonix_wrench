import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_service.dart';
import '../../core/billing/billing_controller.dart';
import '../../core/billing/billing_gate.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/services/pdf_service.dart';
import '../../core/services/shop_logo_service.dart';
import '../../core/settings/app_settings.dart';
import '../../core/utils/secure_logger.dart';
import '../../shared/widgets/app_header.dart';
import '../../shared/widgets/block_layout.dart';
import '../../shared/widgets/surface_card.dart';
import '../auth/organization_screen.dart';
import '../billing/billing_screen.dart';
import '../../core/theme/app_theme.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settings = context.watch<AppSettings>();

    return BlockScaffold(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppHeaderBar(),
          const SizedBox(height: AppTheme.space8),
          Text(
            l10n.t(AppStrings.navSettings),
            style: theme.textTheme.displaySmall?.copyWith(color: p.onBlock),
          ),
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space5,
          AppTheme.space6,
          AppTheme.space5,
          AppTheme.navClearance,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsSection(
                  icon: Icons.contrast_rounded,
                  title: l10n.t(AppStrings.settingsAppearance),
                  child: SegmentedButton<AppThemeMode>(
                    // Icon-only: three labelled segments wrapped onto two lines
                    // on a phone, which is what made this control look broken.
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: AppThemeMode.dark,
                        label: Text(l10n.t(AppStrings.settingsThemeDark)),
                      ),
                      ButtonSegment(
                        value: AppThemeMode.light,
                        label: Text(l10n.t(AppStrings.settingsThemeLight)),
                      ),
                      ButtonSegment(
                        value: AppThemeMode.system,
                        label: Text(l10n.t(AppStrings.settingsThemeSystem)),
                      ),
                    ],
                    selected: {settings.themeMode},
                    onSelectionChanged: (selection) => settings.setThemeMode(selection.first),
                  ),
                ),
                const SizedBox(height: AppTheme.space4),
                _SettingsSection(
                  icon: Icons.translate_rounded,
                  title: l10n.t(AppStrings.settingsLanguage),
                  child: DropdownButtonFormField<AppLanguage>(
                    initialValue: settings.language,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    items: [
                      for (final language in AppLanguage.values)
                        DropdownMenuItem(value: language, child: Text(language.nativeName)),
                    ],
                    onChanged: (language) {
                      if (language != null) settings.setLanguage(language);
                    },
                  ),
                ),
                const SizedBox(height: AppTheme.space4),
                _SettingsSection(
                  icon: Icons.payments_outlined,
                  title: l10n.t(AppStrings.settingsCurrency),
                  child: DropdownButtonFormField<AppCurrency>(
                    initialValue: settings.currency,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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
                const SizedBox(height: AppTheme.space4),
                const _PdfFolderSection(),
                const SizedBox(height: AppTheme.space4),
                const _ShopLogoSection(),
                const SizedBox(height: AppTheme.space8),
                SectionHeading(title: l10n.t(AppStrings.settingsOrganization)),
                const SizedBox(height: AppTheme.space4),
                _NavRow(
                  icon: Icons.groups_outlined,
                  title: l10n.t(AppStrings.settingsOrganizationManage),
                  subtitle: l10n.t(AppStrings.settingsOrganizationDescription),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const OrganizationScreen()),
                  ),
                ),
                const SizedBox(height: AppTheme.space3),
                _NavRow(
                  icon: Icons.workspace_premium_outlined,
                  tone: TileTone.accent,
                  title: l10n.t(AppStrings.settingsSubscriptionManage),
                  subtitle: l10n.t(AppStrings.settingsSubscriptionDescription),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const BillingScreen()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Where generated job-card PDFs are written.
///
/// The resolved default is shown rather than the word "default", because
/// "Downloads" means a different absolute path per platform and per machine,
/// and the point of this setting is knowing where the file went.
class _PdfFolderSection extends StatefulWidget {
  const _PdfFolderSection();

  @override
  State<_PdfFolderSection> createState() => _PdfFolderSectionState();
}

class _PdfFolderSectionState extends State<_PdfFolderSection> {
  String? _resolvedDefault;

  @override
  void initState() {
    super.initState();
    _loadDefault();
  }

  Future<void> _loadDefault() async {
    final directory = await PdfService.resolveTargetDirectory(null);
    if (mounted) setState(() => _resolvedDefault = directory.path);
  }

  Future<void> _choose() async {
    final settings = context.read<AppSettings>();
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await getDirectoryPath();
      if (path == null) return; // cancelled
      await settings.setPdfDirectory(path);
    } catch (e, stackTrace) {
      AppLogger.warn('SettingsView: folder picker failed', e, stackTrace);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.t(AppStrings.settingsPdfFolderError))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final settings = context.watch<AppSettings>();
    final chosen = settings.pdfDirectory;

    return _SettingsSection(
      icon: Icons.folder_outlined,
      title: l10n.t(AppStrings.settingsPdfFolder),
      description: l10n.t(AppStrings.settingsPdfFolderDescription),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SurfaceWell(
            child: Row(
              children: [
                Icon(Icons.subdirectory_arrow_right_rounded, size: 17, color: p.inkTertiary),
                const SizedBox(width: AppTheme.space2),
                Expanded(
                  child: Text(
                    chosen ?? _resolvedDefault ?? '…',
                    style: theme.textTheme.bodySmall?.copyWith(color: p.inkSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.space4),
          Wrap(
            spacing: AppTheme.space3,
            runSpacing: AppTheme.space3,
            children: [
              _CompactButton(
                icon: Icons.folder_open_outlined,
                label: l10n.t(AppStrings.settingsPdfFolderChoose),
                onPressed: _choose,
              ),
              if (chosen != null)
                _CompactButton(
                  label: l10n.t(AppStrings.settingsPdfFolderReset),
                  onPressed: () => settings.setPdfDirectory(null),
                ),
            ],
          ),
        ],
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
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return _SettingsSection(
      icon: Icons.image_outlined,
      title: l10n.t(AppStrings.settingsShopLogo),
      description: l10n.t(AppStrings.settingsShopLogoDescription),
      child: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 88,
                  width: double.infinity,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: AppTheme.space4),
                  decoration: BoxDecoration(
                    // Deliberately paper-white in both themes: this previews the
                    // header of a printed PDF, and shop logos are drawn in dark
                    // ink for paper. On the dark surface tone it used to sit on,
                    // a dark-ink logo was invisible.
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  child: _logoBytes != null
                      ? Image.memory(
                          _logoBytes!,
                          fit: BoxFit.contain,
                          height: 60,
                          // A corrupt or non-image response must not take the
                          // whole settings screen down with an exception.
                          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                        )
                      : Text(
                          l10n.t(AppStrings.settingsShopLogoDefaultLabel),
                          style: theme.textTheme.bodySmall?.copyWith(
                            // Fixed grey, not a palette token: this sits on the
                            // always-white paper preview.
                            color: const Color(0xFF9E948A),
                          ),
                        ),
                ),
                const SizedBox(height: AppTheme.space4),
                Row(
                  children: [
                    _CompactButton(
                      icon: Icons.upload_outlined,
                      label: l10n.t(AppStrings.settingsShopLogoUpload),
                      onPressed: _busy ? null : _pickAndUpload,
                    ),
                    if (_hasCustomLogo) ...[
                      const SizedBox(width: AppTheme.space3),
                      _CompactButton(
                        icon: Icons.delete_outline,
                        label: l10n.t(AppStrings.settingsShopLogoRemove),
                        onPressed: _busy ? null : _remove,
                        foreground: p.danger,
                      ),
                    ],
                    if (_busy) ...[
                      const SizedBox(width: AppTheme.space3),
                      const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ],
            ),
    );
  }
}

/// One settings card: icon tile, title, optional description, then the control.
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.child,
    this.description,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.all(AppTheme.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon, size: 38),
              const SizedBox(width: AppTheme.space3),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: AppTheme.space3),
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(color: p.inkSecondary),
            ),
          ],
          const SizedBox(height: AppTheme.space4),
          child,
        ],
      ),
    );
  }
}

/// A tappable card row that leads somewhere else.
///
/// Replaces the tonal `FilledButton.tonalIcon` these two used to be: a button
/// buried at the bottom of a card reads as a minor action, but Organization
/// and Subscription are whole screens.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tone = TileTone.secondary,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final TileTone tone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.all(AppTheme.space4),
      onTap: onTap,
      child: Row(
        children: [
          IconTile(icon, size: 44, tone: tone),
          const SizedBox(width: AppTheme.space4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: p.inkTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.space2),
          Icon(Icons.chevron_right_rounded, color: p.inkTertiary),
        ],
      ),
    );
  }
}

/// A small pill button for secondary actions inside a settings card.
///
/// The theme's buttons are 54px pills built for primary CTAs; several of those
/// stacked inside a card overwhelmed the setting they belonged to.
class _CompactButton extends StatelessWidget {
  const _CompactButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.foreground,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onPressed != null;
    final fg = !enabled ? p.inkTertiary : (foreground ?? p.ink);

    return Material(
      color: p.surfaceMuted,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space4,
            vertical: AppTheme.space3,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: AppTheme.space2),
              ],
              Text(
                label,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
