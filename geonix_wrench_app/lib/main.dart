import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/auth/auth_service.dart';
import 'core/billing/billing_controller.dart';
import 'core/services/billing_service.dart';
import 'core/services/recent_activity_store.dart';
import 'core/services/user_profile_service.dart';
import 'core/settings/app_settings.dart';
import 'core/user/user_profile_controller.dart';
import 'firebase_options.dart';
import 'core/config/app_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Surface a missing backend host immediately, rather than letting every
  // request fail later with an opaque connection error.
  assertApiBaseUrlConfigured();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final settings = AppSettings();
  await settings.load();

  // Loaded up front for the same reason as settings: the record screen reads
  // it on its first frame, and this history lives only on this device.
  final recentActivity = RecentActivityStore();
  await recentActivity.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: recentActivity),
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProxyProvider<AuthService, UserProfileController>(
          create: (context) => UserProfileController(
            authService: context.read<AuthService>(),
            service: UserProfileService(authService: context.read<AuthService>()),
          ),
          update: (context, authService, previous) =>
              previous ??
              UserProfileController(
                authService: authService,
                service: UserProfileService(authService: authService),
              ),
        ),
        ChangeNotifierProxyProvider2<AuthService, UserProfileController, BillingController>(
          create: (context) => BillingController(
            authService: context.read<AuthService>(),
            profileController: context.read<UserProfileController>(),
            service: BillingService(authService: context.read<AuthService>()),
          ),
          update: (context, authService, profileController, previous) =>
              previous ??
              BillingController(
                authService: authService,
                profileController: profileController,
                service: BillingService(authService: authService),
              ),
        ),
      ],
      child: const GeonixWrenchApp(),
    ),
  );
}
