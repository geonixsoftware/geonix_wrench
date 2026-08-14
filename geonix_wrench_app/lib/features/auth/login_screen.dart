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
import 'signup_screen.dart';

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
    } on FirebaseAuthException catch (e) {
      _showError(mapFirebaseAuthException(e).message);
    } catch (_) {
      _showError(l10n.t(AppStrings.authGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final l10n = context.l10n;
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showError(l10n.t(AppStrings.authEmailRequired));
      return;
    }
    try {
      await context.read<AuthService>().sendPasswordReset(email);
      _showError(l10n.t(AppStrings.authPasswordResetSent));
    } on FirebaseAuthException catch (e) {
      _showError(mapFirebaseAuthException(e).message);
    } catch (_) {
      _showError(l10n.t(AppStrings.authGenericError));
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
                          Text(l10n.t(AppStrings.authLoginTitle), style: Theme.of(context).textTheme.titleLarge),
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
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _busy ? null : _forgotPassword,
                              child: Text(l10n.t(AppStrings.authForgotPassword)),
                            ),
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : Text(l10n.t(AppStrings.authSignInButton)),
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
                              Text(l10n.t(AppStrings.authNoAccountPrompt)),
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
