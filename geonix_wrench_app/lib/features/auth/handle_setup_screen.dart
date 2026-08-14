import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_service.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/services/user_profile_service.dart';
import '../../core/user/user_profile_controller.dart';
import '../../shared/widgets/surface_card.dart';

final RegExp _handleRegex = RegExp(r'^[a-z0-9_]+$');

class HandleSetupScreen extends StatefulWidget {
  const HandleSetupScreen({super.key});

  @override
  State<HandleSetupScreen> createState() => _HandleSetupScreenState();
}

class _HandleSetupScreenState extends State<HandleSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _handleController = TextEditingController();
  late final UserProfileService _service;
  bool _busy = false;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    _service = UserProfileService(authService: context.read<AuthService>());
  }

  @override
  void dispose() {
    _handleController.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    final l10n = context.l10n;
    final handle = (value ?? '').trim();
    if (handle.length < 3 || handle.length > 30) {
      return l10n.t(AppStrings.handleSetupLengthError);
    }
    if (!_handleRegex.hasMatch(handle)) {
      return l10n.t(AppStrings.handleSetupInvalid);
    }
    return null;
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    setState(() => _serverError = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    try {
      await _service.claimHandle(_handleController.text.trim());
      if (!mounted) return;
      await context.read<UserProfileController>().refresh();
    } on UserProfileException catch (e) {
      final message = e.message.toLowerCase().contains('taken')
          ? l10n.t(AppStrings.handleSetupTaken)
          : e.message;
      if (mounted) setState(() => _serverError = message);
    } catch (_) {
      if (mounted) setState(() => _serverError = l10n.t(AppStrings.authGenericError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SurfaceCard(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(l10n.t(AppStrings.handleSetupTitle), style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      Text(
                        l10n.t(AppStrings.handleSetupDescription),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _handleController,
                        autocorrect: false,
                        inputFormatters: [
                          FilteringTextInputFormatter.deny(RegExp(r'\s')),
                          TextInputFormatter.withFunction(
                            (oldValue, newValue) => newValue.copyWith(text: newValue.text.toLowerCase()),
                          ),
                        ],
                        decoration: InputDecoration(
                          labelText: l10n.t(AppStrings.handleSetupLabel),
                          hintText: l10n.t(AppStrings.handleSetupHint),
                        ),
                        validator: _validate,
                      ),
                      if (_serverError != null) ...[
                        const SizedBox(height: 8),
                        Text(_serverError!, style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(l10n.t(AppStrings.handleSetupSubmit)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
