import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

class JobCardFieldTile extends StatelessWidget {
  const JobCardFieldTile({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Uppercase eyebrow rather than sentence-case grey text: it reads as
          // a field label instead of as a second, quieter sentence.
          Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
          const SizedBox(height: AppTheme.space2),
          Text(value, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}
