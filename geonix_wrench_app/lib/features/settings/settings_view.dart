import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/auth_service.dart';
import '../../core/billing/billing_controller.dart';
import '../../core/billing/billing_gate.dart';
import '../../core/config/app_config.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/services/pdf_service.dart';
import '../../core/services/recent_activity_store.dart';
import '../../core/services/shop_logo_service.dart';
import '../../core/services/user_profile_service.dart';
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
    final l10n = context.l10n;
    final settings = context.watch<AppSettings>();

    return BlockScaffold(
      // The screen name rides beside the wordmark rather than under it as a
      // 34px headline: this block was two-thirds empty near-black before the
      // first setting appeared.
      headerPadding: BlockScaffold.compactHeaderPadding,
      header: AppHeaderBar(label: l10n.t(AppStrings.navSettings)),
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
                const _RecentActivitySection(),
                const SizedBox(height: AppTheme.space4),
                const _PdfFolderSection(),
                const SizedBox(height: AppTheme.space4),
                const _ShopLogoSection(),
                // Debug builds only. kDebugMode is a compile-time constant, so
                // this whole widget is tree-shaken out of a release build —
                // there is no hidden setting for anyone to find.
                if (kDebugMode) ...[
                  const SizedBox(height: AppTheme.space4),
                  const _DevServerSection(),
                ],
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
                const SizedBox(height: AppTheme.space8),
                SectionHeading(title: l10n.t(AppStrings.settingsLegal)),
                const SizedBox(height: AppTheme.space4),
                _NavRow(
                  icon: Icons.privacy_tip_outlined,
                  tone: TileTone.neutral,
                  title: l10n.t(AppStrings.settingsPrivacy),
                  subtitle: l10n.t(AppStrings.settingsPrivacyDescription),
                  onTap: () => _openExternal(context, kPrivacyPolicyUrl),
                ),
                const SizedBox(height: AppTheme.space3),
                _NavRow(
                  icon: Icons.gavel_rounded,
                  tone: TileTone.neutral,
                  title: l10n.t(AppStrings.settingsTerms),
                  subtitle: l10n.t(AppStrings.settingsTermsDescription),
                  onTap: () => _openExternal(context, kTermsUrl),
                ),
                const SizedBox(height: AppTheme.space8),
                SectionHeading(title: l10n.t(AppStrings.settingsAccount)),
                const SizedBox(height: AppTheme.space4),
                const _AccountSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Which backend this build talks to, changeable without rebuilding.
///
/// Exists because the address is otherwise compiled in, and the two ways to
/// reach a laptop from a phone both move: a LAN address changes with the
/// network, and a free tunnel hands out a new URL every restart. Rebuilding and
/// reinstalling for each of those is what made testing on a real device slow
/// enough to avoid.
///
/// Debug builds only — see [apiBaseUrl]. A release build ignores the stored
/// value entirely, so this cannot become a way to aim a shipped app at
/// someone else's server.
class _DevServerSection extends StatefulWidget {
  const _DevServerSection();

  @override
  State<_DevServerSection> createState() => _DevServerSectionState();
}

class _DevServerSectionState extends State<_DevServerSection> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: context.read<AppSettings>().apiBaseUrlOverride ?? '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final settings = context.read<AppSettings>();
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);

    final accepted = await settings.setApiBaseUrlOverride(_controller.text);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          accepted
              ? l10n
                    .t(AppStrings.settingsDevServerSaved)
                    .replaceAll('{url}', settings.effectiveApiBaseUrl)
              : l10n.t(AppStrings.settingsDevServerInvalid),
        ),
      ),
    );
  }

  Future<void> _reset() async {
    final settings = context.read<AppSettings>();
    await settings.setApiBaseUrlOverride(null);
    if (mounted) _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final theme = Theme.of(context);
    final settings = context.watch<AppSettings>();

    return _SettingsSection(
      icon: Icons.dns_outlined,
      title: l10n.t(AppStrings.settingsDevServer),
      description: l10n.t(AppStrings.settingsDevServerDescription),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The resolved address, not the stored override: with the field empty
          // this is the compiled-in default, and "which server am I actually
          // talking to" should never need working out.
          SurfaceWell(
            child: Row(
              children: [
                ToneChip(
                  label: l10n.t(AppStrings.settingsDevServerInUse),
                  tone: settings.apiBaseUrlOverride == null
                      ? ChipTone.neutral
                      : ChipTone.accent,
                ),
                const SizedBox(width: AppTheme.space3),
                Expanded(
                  child: Text(
                    settings.effectiveApiBaseUrl,
                    style: theme.textTheme.bodySmall?.copyWith(color: p.inkSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.space4),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l10n.t(AppStrings.settingsDevServerLabel),
              hintText: l10n.t(AppStrings.settingsDevServerHint),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: AppTheme.space4),
          Wrap(
            spacing: AppTheme.space3,
            runSpacing: AppTheme.space3,
            children: [
              _CompactButton(
                icon: Icons.check_rounded,
                label: l10n.t(AppStrings.settingsDevServerSave),
                onPressed: _save,
              ),
              if (settings.apiBaseUrlOverride != null)
                _CompactButton(
                  label: l10n.t(AppStrings.settingsDevServerReset),
                  onPressed: _reset,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// How many finished jobs the record screen remembers.
///
/// The list is kept in the app's own preferences on this phone, so the ceiling
/// is a retention choice, not a display one: lowering it forgets the entries it
/// drops, and 0 means the app keeps no job history at all.
class _RecentActivitySection extends StatelessWidget {
  const _RecentActivitySection();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final store = context.watch<RecentActivityStore>();

    return _SettingsSection(
      icon: Icons.history_rounded,
      title: l10n.t(AppStrings.settingsRecentActivity),
      description: l10n.t(AppStrings.settingsRecentActivityDescription),
      child: DropdownButtonFormField<int>(
        initialValue: store.limit,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        items: [
          for (var count = RecentActivityStore.minLimit;
              count <= RecentActivityStore.maxLimit;
              count++)
            DropdownMenuItem(
              value: count,
              child: Text(
                count == 0
                    ? l10n.t(AppStrings.settingsRecentActivityOff)
                    : l10n
                        .t(AppStrings.settingsRecentActivityCount)
                        .replaceAll('{n}', '$count'),
              ),
            ),
        ],
        onChanged: (count) {
          if (count != null) store.setLimit(count);
        },
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
    // Nothing on iOS reads this, and resolving it costs a write probe.
    if (_isIos) return;
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

  /// iOS gives an app no shared storage and no directory picker, so the folder
  /// is neither choosable nor worth printing: the container path it resolves to
  /// carries a UUID that changes on every app update. The route to the files is
  /// the Files app, so that is what the setting names.
  bool get _isIos => !kIsWeb && Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = context.palette;
    final settings = context.watch<AppSettings>();
    final chosen = settings.pdfDirectory;

    final location = _isIos
        ? l10n.t(AppStrings.settingsPdfFolderIosLocation)
        : (chosen ?? _resolvedDefault ?? '…');

    return _SettingsSection(
      icon: Icons.folder_outlined,
      title: l10n.t(AppStrings.settingsPdfFolder),
      description: _isIos
          ? l10n.t(AppStrings.settingsPdfFolderIosNote)
          : l10n.t(AppStrings.settingsPdfFolderDescription),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SurfaceWell(
            child: Row(
              children: [
                Icon(
                  _isIos ? Icons.folder_special_outlined : Icons.subdirectory_arrow_right_rounded,
                  size: 17,
                  color: p.inkTertiary,
                ),
                const SizedBox(width: AppTheme.space2),
                Expanded(
                  child: Text(
                    location,
                    style: theme.textTheme.bodySmall?.copyWith(color: p.inkSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (!_isIos) ...[
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
        ],
      ),
    );
  }
}

/// Sign out, and close the account for good.
///
/// Account deletion is not a nicety here: GDPR gives an EU customer the right to
/// erasure, and the App Store rejects an app that creates accounts with no way
/// to close one. The product is priced in EUR for European shops, so both bind.
///
/// Sits beside sign-out on purpose — that is where a user looks for it, and
/// putting the reversible action next to the irreversible one makes the
/// difference between them legible.
class _AccountSection extends StatefulWidget {
  const _AccountSection();

  @override
  State<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<_AccountSection> {
  bool _deleting = false;

  Future<void> _confirmAndDelete() async {
    final l10n = context.l10n;
    final p = context.palette;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.t(AppStrings.settingsDeleteAccountConfirmTitle)),
        content: Text(l10n.t(AppStrings.settingsDeleteAccountConfirmMessage)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.t(AppStrings.cancel)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: p.danger),
            child: Text(l10n.t(AppStrings.settingsDeleteAccountConfirmAction)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final authService = context.read<AuthService>();
    final recentActivity = context.read<RecentActivityStore>();
    final service = UserProfileService(authService: authService);

    setState(() => _deleting = true);
    try {
      await service.deleteAccount();

      // The on-device history is the app's own copy of what was just erased on
      // the server. Leaving it behind would mean a deleted account's job titles
      // still listed on the record screen.
      await recentActivity.clear();
      await authService.signOut();
      // No navigation: AuthGate is watching AuthService and swaps to the login
      // screen the moment the sign-out lands.
    } on UserProfileException catch (e) {
      if (!mounted) return;
      // The server's own wording, not a generic failure: a 409 here means the
      // caller still owns a shop with other mechanics in it, and that is
      // actionable only if it is said out loud.
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e, stackTrace) {
      AppLogger.error('SettingsView: account deletion failed', e, stackTrace);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.t(AppStrings.settingsDeleteAccountError))),
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NavRow(
          icon: Icons.logout_rounded,
          title: l10n.t(AppStrings.settingsSignOut),
          subtitle: l10n.t(AppStrings.settingsSignOutDescription),
          onTap: () => context.read<AuthService>().signOut(),
        ),
        const SizedBox(height: AppTheme.space3),
        _NavRow(
          icon: Icons.person_remove_outlined,
          tone: TileTone.neutral,
          title: l10n.t(AppStrings.settingsDeleteAccount),
          subtitle: l10n.t(AppStrings.settingsDeleteAccountDescription),
          titleColor: p.danger,
          trailing: _deleting
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: _deleting ? null : _confirmAndDelete,
        ),
      ],
    );
  }
}

/// Opens a legal page in the browser rather than an in-app webview: these have
/// to be readable, shareable and printable, and a webview gives up all three.
Future<void> _openExternal(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  try {
    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!launched) throw Exception('launchUrl returned false');
  } catch (e, stackTrace) {
    AppLogger.warn('SettingsView: could not open $url', e, stackTrace);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.t(AppStrings.billingLaunchError))),
    );
  }
}

enum _LogoSource { photos, files }

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

  /// Logo formats the backend accepts.
  ///
  /// SVG is first because it is what a shop's designer actually hands over —
  /// the previous gallery-only picker could not even see one, since a vector
  /// file never lands in the phone's photo library.
  static const _acceptedExtensions = <String>[
    'svg',
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
    'bmp',
    'tif',
    'tiff',
    'heic',
    'heif',
  ];

  Future<void> _pickAndUpload() async {
    if (!context.read<BillingController>().isActive) {
      await showSubscriptionRequiredDialog(context);
      return;
    }

    // On a phone the two sources are genuinely different places — a photo of a
    // sign lives in Photos, an SVG or a PNG from the designer lives in Files —
    // and neither picker can reach the other. On desktop there is only one.
    final useSourceSheet = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final source = useSourceSheet ? await _askSource() : _LogoSource.files;
    if (source == null || !mounted) return;

    final ({Uint8List bytes, String name})? picked = switch (source) {
      _LogoSource.photos => await _pickFromPhotos(),
      _LogoSource.files => await _pickFromFiles(),
    };
    if (picked == null || !mounted) return;

    final extension = picked.name.split('.').last.toLowerCase();
    if (!_acceptedExtensions.contains(extension)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.t(AppStrings.settingsShopLogoUnsupported))),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      await _service.uploadLogo(picked.bytes, picked.name);
      await _load();
    } catch (e, stackTrace) {
      AppLogger.warn('SettingsView: shop logo upload failed', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.t(AppStrings.settingsShopLogoUploadError))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_LogoSource?> _askSource() {
    final l10n = context.l10n;
    return showModalBottomSheet<_LogoSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.space5,
                AppTheme.space5,
                AppTheme.space5,
                AppTheme.space2,
              ),
              child: SectionHeading(title: l10n.t(AppStrings.settingsShopLogoSourceTitle)),
            ),
            ListTile(
              leading: const IconTile(Icons.photo_library_outlined, size: 40),
              title: Text(l10n.t(AppStrings.settingsShopLogoSourcePhotos)),
              onTap: () => Navigator.of(sheetContext).pop(_LogoSource.photos),
            ),
            ListTile(
              leading: const IconTile(Icons.folder_open_outlined, size: 40),
              title: Text(l10n.t(AppStrings.settingsShopLogoSourceFiles)),
              subtitle: Text(l10n.t(AppStrings.settingsShopLogoFormats)),
              onTap: () => Navigator.of(sheetContext).pop(_LogoSource.files),
            ),
            const SizedBox(height: AppTheme.space4),
          ],
        ),
      ),
    );
  }

  Future<({Uint8List bytes, String name})?> _pickFromPhotos() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return null;
    return (bytes: await picked.readAsBytes(), name: picked.name);
  }

  Future<({Uint8List bytes, String name})?> _pickFromFiles() async {
    // Both a MIME list and an extension list: Android's picker filters on MIME
    // and would otherwise grey out every SVG, while macOS and Windows filter on
    // extension and ignore MIME entirely.
    const group = XTypeGroup(
      label: 'Images',
      extensions: _acceptedExtensions,
      mimeTypes: [
        'image/svg+xml',
        'image/png',
        'image/jpeg',
        'image/webp',
        'image/gif',
        'image/bmp',
        'image/tiff',
        'image/heic',
        'image/heif',
      ],
      uniformTypeIdentifiers: ['public.image', 'public.svg-image'],
    );

    try {
      final file = await openFile(acceptedTypeGroups: const [group]);
      if (file == null) return null;
      return (bytes: await file.readAsBytes(), name: file.name);
    } catch (e, stackTrace) {
      AppLogger.warn('SettingsView: file picker failed', e, stackTrace);
      return null;
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
      description: '${l10n.t(AppStrings.settingsShopLogoDescription)} '
          '${l10n.t(AppStrings.settingsShopLogoFormats)}',
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
                      ? _LogoPreview(bytes: _logoBytes!)
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

/// The stored shop logo, whichever of the two shapes it comes back as.
///
/// The server keeps an SVG upload as SVG rather than flattening it, so this
/// endpoint can return either vector or raster. The bytes are sniffed instead
/// of trusting a content type, so a proxy that rewrites headers cannot turn the
/// preview into a broken image.
class _LogoPreview extends StatelessWidget {
  const _LogoPreview({required this.bytes});

  final Uint8List bytes;

  bool get _isSvg {
    final head = String.fromCharCodes(bytes.take(256)).trimLeft();
    return head.startsWith('<svg') || (head.startsWith('<?xml') && head.contains('<svg'));
  }

  @override
  Widget build(BuildContext context) {
    if (_isSvg) {
      return SvgPicture.memory(
        bytes,
        fit: BoxFit.contain,
        height: 60,
        placeholderBuilder: (_) => const SizedBox.shrink(),
      );
    }

    return Image.memory(
      bytes,
      fit: BoxFit.contain,
      height: 60,
      // A corrupt or non-image response must not take the whole settings
      // screen down with an exception.
      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
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
    this.titleColor,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// Null disables the row — used while a destructive action is in flight, so a
  /// second tap cannot start it twice.
  final VoidCallback? onTap;
  final TileTone tone;

  /// Marks a destructive row without turning the whole tile red.
  final Color? titleColor;

  /// Replaces the chevron — a spinner, for a row that acts instead of
  /// navigating.
  final Widget? trailing;

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
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(color: titleColor),
                ),
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
          trailing ?? Icon(Icons.chevron_right_rounded, color: p.inkTertiary),
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
