import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_exceptions.dart';
import '../../core/auth/auth_service.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../shared/widgets/block_layout.dart';
import '../../shared/widgets/geonix_logo.dart';
import 'signup_screen.dart';
import 'widgets/password_field.dart';
import '../../core/theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await context.read<AuthService>().signInWithEmail(
            _emailController.text.trim(),
            _passwordController.text,
          );
    } on FirebaseAuthException catch (e) {
      _showError(mapFirebaseAuthException(e).message);
    } catch (e, stackTrace) {
      debugPrint('LoginScreen._submit failed: $e\n$stackTrace');
      _showError(describeUnexpectedAuthError(e, l10n.t(AppStrings.authGenericError)));
      rethrow;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the reset-password dialog, pre-filled with whatever is currently in
  /// the email field so the user can confirm or correct it before sending.
  Future<void> _forgotPassword() async {
    final l10n = context.l10n;
    final authService = context.read<AuthService>();

    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _ResetPasswordDialog(
        initialEmail: _emailController.text.trim(),
      ),
    );

    // Dialog dismissed / cancelled.
    if (email == null || !mounted) return;

    try {
      await authService.sendPasswordReset(email);
      if (!mounted) return;
      _showError(
        l10n.t(AppStrings.authResetDialogCheckSpam).replaceAll('{email}', email),
      );
    } on FirebaseAuthException catch (e) {
      _showError(mapFirebaseAuthException(e).message);
    } catch (e, stackTrace) {
      debugPrint('LoginScreen._forgotPassword failed: $e\n$stackTrace');
      _showError(describeUnexpectedAuthError(e, l10n.t(AppStrings.authGenericError)));
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return AuthBlockScaffold(
      title: l10n.t(AppStrings.authLoginTitle),
      subtitle: l10n.t(AppStrings.authLoginSubtitle),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: l10n.t(AppStrings.authEmailLabel),
                prefixIcon: const Icon(Icons.mail_outline),
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? l10n.t(AppStrings.authEmailRequired)
                  : null,
            ),
            const SizedBox(height: AppTheme.space3),
            PasswordField(
              controller: _passwordController,
              label: l10n.t(AppStrings.authPasswordLabel),
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onFieldSubmitted: (_) => _busy ? null : _submit(),
              validator: (value) => (value == null || value.isEmpty)
                  ? l10n.t(AppStrings.authPasswordRequired)
                  : null,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : _forgotPassword,
                child: Text(l10n.t(AppStrings.authForgotPassword)),
              ),
            ),
            const SizedBox(height: AppTheme.space3),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: p.onAccent),
                    )
                  : Text(l10n.t(AppStrings.authSignInButton)),
            ),
            const SizedBox(height: AppTheme.space5),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  l10n.t(AppStrings.authNoAccountPrompt),
                  style: theme.textTheme.bodyMedium,
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push<void>(
                            MaterialPageRoute(builder: (_) => const SignupScreen()),
                          ),
                  child: Text(l10n.t(AppStrings.authSignUpLink)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared shape for every pre-sign-in screen: the brand and the ask on the
/// dark block, the form on the sheet below it.
///
/// The previous auth screens centred a single bordered card on an empty
/// canvas, which is the most anonymous layout a Flutter app can have. Putting
/// the headline on the block gives these screens a top, and means the form
/// starts where the reading stops.
class AuthBlockScaffold extends StatelessWidget {
  const AuthBlockScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.showBack = false,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);

    return BlockScaffold(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                if (showBack) ...[
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: p.onBlock,
                    tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  ),
                  const SizedBox(width: AppTheme.space2),
                ],
                const GeonixLogo(height: 26, onDark: true),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.space10),
          Text(
            title,
            style: theme.textTheme.displaySmall?.copyWith(color: p.onBlock),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: AppTheme.space3),
            Text(
              subtitle!,
              style: theme.textTheme.bodyLarge?.copyWith(color: p.onBlockMuted),
            ),
          ],
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space6,
          AppTheme.space8,
          AppTheme.space6,
          AppTheme.space10,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Confirmation dialog for "Forgot password?".
///
/// Pre-fills [initialEmail] (taken from the sign-in form's email field) so the
/// user only has to confirm it, but keeps it editable in case they want the
/// link sent somewhere else. Pops with the trimmed address, or null on cancel.
class _ResetPasswordDialog extends StatefulWidget {
  const _ResetPasswordDialog({required this.initialEmail});

  final String initialEmail;

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  late final TextEditingController _controller;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialEmail);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AlertDialog(
      title: Text(l10n.t(AppStrings.authResetDialogTitle)),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t(AppStrings.authResetDialogDescription),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppTheme.space5),
            TextFormField(
              controller: _controller,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.t(AppStrings.authEmailLabel),
                prefixIcon: const Icon(Icons.mail_outline),
              ),
              onFieldSubmitted: (_) => _submit(),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? l10n.t(AppStrings.authEmailRequired)
                  : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t(AppStrings.authResetDialogCancel)),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.t(AppStrings.authResetDialogSend)),
        ),
      ],
    );
  }
}
