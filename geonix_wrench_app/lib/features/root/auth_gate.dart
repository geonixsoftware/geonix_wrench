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

    if (profileController.isLoading) {
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
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            GeonixLogo(height: 40),
            SizedBox(height: 24),
            CircularProgressIndicator(strokeWidth: 2),
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
    final l10n = context.l10n;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(l10n.t(AppStrings.authGenericError)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: Text(l10n.t(AppStrings.retry))),
          ],
        ),
      ),
    );
  }
}
