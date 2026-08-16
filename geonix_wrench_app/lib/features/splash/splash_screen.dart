import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/app_strings.dart';
import '../../shared/widgets/geonix_logo.dart';
import '../root/auth_gate.dart';
import '../../core/theme/app_theme.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();

    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AuthGate()),
      );
    });
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);

    // Full-bleed near-black rather than the light canvas: the app now opens
    // the block, so the splash is the first frame of that block instead of a
    // white screen that flips dark a second later.
    return Scaffold(
      backgroundColor: p.block,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          statusBarBrightness: Brightness.dark,
        ),
        child: Center(
          child: FadeTransition(
            opacity: CurvedAnimation(parent: _entrance, curve: Curves.easeOut),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.06),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const GeonixLogo(height: 52, onDark: true),
                  const SizedBox(height: AppTheme.space5),
                  Text(
                    context.l10n.t(AppStrings.splashTagline),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: p.onBlockMuted),
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
