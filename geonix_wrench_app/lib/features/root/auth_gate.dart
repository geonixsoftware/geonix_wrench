import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/auth_service.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/user/user_profile_controller.dart';
import '../../shared/widgets/geonix_logo.dart';
import '../auth/handle_setup_screen.dart';
import '../auth/login_screen.dart';
import '../auth/org_onboarding_screen.dart';
import 'root_shell.dart';
import '../../core/theme/app_theme.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  static const _orgPromptDismissedKey = 'onboarding.org_prompt_dismissed';

  bool? _orgPromptDismissed;

  @override
  void initState() {
    super.initState();
    _loadOrgPromptDismissed();
  }

  Future<void> _loadOrgPromptDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _orgPromptDismissed = prefs.getBool(_orgPromptDismissedKey) ?? false);
  }

  Future<void> _dismissOrgPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_orgPromptDismissedKey, true);
    if (mounted) setState(() => _orgPromptDismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    final authService = context.watch<AuthService>();
    final profileController = context.watch<UserProfileController>();

    if (!authService.isLoaded || _orgPromptDismissed == null) {
      return const _LoadingScreen();
    }

    if (!authService.isSignedIn) {
      return const LoginScreen();
    }

    // Only block on the *first* load. Later refreshes keep the current screen
    // on-screen and update in place, so routine actions no longer flash the
    // whole app back to a spinner.
    if (profileController.isInitialLoad) {
      return const _LoadingScreen();
    }

    final profile = profileController.profile;
    if (profile == null) {
      return _RetryScreen(onRetry: profileController.refresh);
    }

    if (profile.handle == null) {
      return const HandleSetupScreen();
    }

    if (!profile.hasOrganization && !_orgPromptDismissed!) {
      return OrgOnboardingScreen(onSkip: _dismissOrgPrompt);
    }

    return const RootShell();
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    // Matches the splash exactly, so the handover between the two is
    // invisible instead of a flash from black to white and back.
    return Scaffold(
      backgroundColor: p.block,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const GeonixLogo(height: 44, onDark: true),
            const SizedBox(height: AppTheme.space8),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _RetryScreen extends StatelessWidget {
  const _RetryScreen({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: p.canvas,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.space8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(color: p.surfaceMuted, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: Icon(Icons.cloud_off_rounded, size: 32, color: p.inkTertiary),
                ),
                const SizedBox(height: AppTheme.space6),
                Text(
                  l10n.t(AppStrings.authOfflineTitle),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: AppTheme.space3),
                Text(
                  // The old copy was a bare "Something went wrong", which gave
                  // no hint that the backend simply wasn't reachable.
                  l10n.t(AppStrings.authOfflineMessage),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: p.inkSecondary),
                ),
                const SizedBox(height: AppTheme.space8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onRetry,
                    child: Text(l10n.t(AppStrings.retry)),
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
