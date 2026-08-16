import 'package:flutter/material.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/l10n/app_strings.dart';

/// A password input with a show/hide toggle.
///
/// Masking is on by default and the eye button reveals the text, so users can
/// check what they typed instead of guessing — which is the main cause of
/// "passwords do not match" on the sign-up form.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.validator,
    this.textInputAction,
    this.onFieldSubmitted,
    this.autofillHints,
  });

  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final TextInputAction? textInputAction;
  final void Function(String)? onFieldSubmitted;
  final Iterable<String>? autofillHints;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final revealLabel =
        l10n.t(_obscured ? AppStrings.authShowPassword : AppStrings.authHidePassword);

    return TextFormField(
      controller: widget.controller,
      obscureText: _obscured,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onFieldSubmitted: widget.onFieldSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(_obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          tooltip: revealLabel,
          // Screen readers announce the action rather than just "button".
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
      validator: widget.validator,
    );
  }
}
