import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_exceptions.dart';
import '../../core/auth/auth_service.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../shared/widgets/geonix_logo.dart';
import '../../shared/widgets/surface_card.dart';

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
    } catch (_) {
      _showError(l10n.t(AppStrings.authGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueWithGoogle() async {
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      await context.read<AuthService>().signInWithGoogle();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on FirebaseAuthException catch (e) {
      _showError(mapFirebaseAuthException(e).message);
    } catch (_) {
      _showError(l10n.t(AppStrings.authGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueWithApple() async {
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      await context.read<AuthService>().signInWithApple();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on FirebaseAuthException catch (e) {
      _showError(mapFirebaseAuthException(e).message);
    } catch (_) {
      _showError(l10n.t(AppStrings.authGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final showApple = !kIsWeb && (Platform.isIOS || Platform.isMacOS);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: GeonixLogo(height: 40)),
                  const SizedBox(height: 24),
                  SurfaceCard(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(l10n.t(AppStrings.authSignUpTitle), style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(labelText: l10n.t(AppStrings.authEmailLabel)),
                            validator: (value) =>
                                (value == null || value.trim().isEmpty) ? l10n.t(AppStrings.authEmailRequired) : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _passwordController,
                            obscureText: true,
                            decoration: InputDecoration(labelText: l10n.t(AppStrings.authPasswordLabel)),
                            validator: (value) =>
                                (value == null || value.isEmpty) ? l10n.t(AppStrings.authPasswordRequired) : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _confirmPasswordController,
                            obscureText: true,
                            decoration: InputDecoration(labelText: l10n.t(AppStrings.authConfirmPasswordLabel)),
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
                          const SizedBox(height: 20),
                          ElevatedButton(
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : Text(l10n.t(AppStrings.authSignUpButton)),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _continueWithGoogle,
                            icon: const Icon(Icons.g_mobiledata_rounded),
                            label: Text(l10n.t(AppStrings.authContinueWithGoogle)),
                          ),
                          if (showApple) ...[
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _continueWithApple,
                              icon: const Icon(Icons.apple),
                              label: Text(l10n.t(AppStrings.authContinueWithApple)),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(l10n.t(AppStrings.authHaveAccountPrompt)),
                              TextButton(
                                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                                child: Text(l10n.t(AppStrings.authSignInLink)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
