import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_exceptions.dart';
import '../../core/auth/auth_service.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import 'login_screen.dart';
import 'widgets/password_field.dart';
import '../../core/theme/app_theme.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
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
      await context.read<AuthService>().signUpWithEmail(
            _emailController.text.trim(),
            _passwordController.text,
          );
      if (!mounted) return;
      // Registration signs the user in automatically — pop this route so the
      // authenticated flow (user name setup) becomes visible.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on FirebaseAuthException catch (e) {
      _showError(mapFirebaseAuthException(e).message);
    } catch (e, stackTrace) {
      debugPrint('SignupScreen._submit failed: $e\n$stackTrace');
      _showError(describeUnexpectedAuthError(e, l10n.t(AppStrings.authGenericError)));
      rethrow;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;

    return AuthBlockScaffold(
      showBack: true,
      title: l10n.t(AppStrings.authSignUpTitle),
      subtitle: l10n.t(AppStrings.authSignUpSubtitle),
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
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.newPassword],
              validator: (value) => (value == null || value.isEmpty)
                  ? l10n.t(AppStrings.authPasswordRequired)
                  : null,
            ),
            const SizedBox(height: AppTheme.space3),
            PasswordField(
              controller: _confirmPasswordController,
              label: l10n.t(AppStrings.authConfirmPasswordLabel),
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              onFieldSubmitted: (_) => _busy ? null : _submit(),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.t(AppStrings.authPasswordRequired);
                }
                if (value != _passwordController.text) {
                  return l10n.t(AppStrings.authPasswordsDoNotMatch);
                }
                return null;
              },
            ),
            const SizedBox(height: AppTheme.space6),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: p.onAccent),
                    )
                  : Text(l10n.t(AppStrings.authSignUpButton)),
            ),
            const SizedBox(height: AppTheme.space4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  l10n.t(AppStrings.authHaveAccountPrompt),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.t(AppStrings.authSignInLink)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
