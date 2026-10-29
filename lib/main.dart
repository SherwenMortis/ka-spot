import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/home_shell.dart';
import 'screens/update_password_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/background_location_service.dart';
import 'services/connectivity_service.dart';
import 'services/kaspot_service.dart';
import 'services/notification_navigation.dart';
import 'services/push_notification_service.dart';
import 'utils/backend_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enforce visible dark status bar icons on light application background
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env is optional when building with --dart-define or CI environments.
    // BackendTarget reads it only when it is actually initialised, so a missing
    // file is "no value" rather than the throw this used to produce.
  }

  final target = BackendTarget.current();
  final targetError = target.configurationError;
  if (targetError != null) {
    // A build that names one backend and points at another cannot be trusted:
    // a staging APK aimed at production would delete real accounts. Nothing is
    // initialised, so nothing can be sent anywhere.
    debugPrint('KaSpot refused to start: $targetError');
    runApp(_MisconfiguredBackendApp(message: targetError));
    return;
  }

  // Initialise Firebase before anything else (required for FCM).
  await Firebase.initializeApp();

  if (target.hasCredentials) {
    await Supabase.initialize(url: target.url, publishableKey: target.anonKey);
    KaSpotService.configure(Supabase.instance.client);
  }
  await ConnectivityService.initialize();
  // Send any location fix that was queued while the phone was offline before
  // the app was last closed.
  unawaited(KaSpotService.flushPendingLocation());
  unawaited(BackgroundLocationService.initialize());
  // Initialise FCM push notifications (Android). Token is registered with
  // Supabase only after the user is authenticated — see PushNotificationService
  // and KaSpotService.registerFcmToken().
  unawaited(PushNotificationService.initialize());
  runApp(const KaSpotApp());
}

class KaSpotApp extends StatefulWidget {
  const KaSpotApp({super.key});

  static const ocean = Color(0xFF1E60AA);
  static const oceanDark = Color(0xFF0F3258);
  static const oceanLight = Color(0xFFEAF3FC);
  static const mint = Color(0xFF10B981);
  static const slateBg = Color(0xFFF8FAFC);
  static const slateText = Color(0xFF0F172A);
  static const mutedText = Color(0xFF64748B);

  @override
  State<KaSpotApp> createState() => _KaSpotAppState();
}

class _KaSpotAppState extends State<KaSpotApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  bool _recoveryScreenShown = false;

  static const ocean = KaSpotApp.ocean;
  static const slateBg = KaSpotApp.slateBg;
  static const slateText = KaSpotApp.slateText;

  @override
  void initState() {
    super.initState();
    // Allow notification taps to resolve into navigation once the root
    // navigator and authenticated session are ready.
    NotificationNavigation.navigatorKey = _navigatorKey;
    KaSpotService.authStateNotifier.addListener(_onAuthChanged);
    KaSpotService.passwordRecoveryActive.addListener(_onRecoveryStateChanged);
  }

  @override
  void dispose() {
    KaSpotService.authStateNotifier.removeListener(_onAuthChanged);
    KaSpotService.passwordRecoveryActive.removeListener(_onRecoveryStateChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!KaSpotService.authStateNotifier.value) {
      // A signed-out or unverified state must never keep streaming location.
      // BackgroundLocationService listens to the same signal and performs the
      // network-independent local stop, notification teardown and consent
      // withdrawal — see BackgroundLocationService.onSignedOut().
      unawaited(BackgroundLocationService.onSignedOut());
    } else {
      // A fix queued while signed out (or offline) can now be safely
      // attributed to the signed-in account and sent.
      unawaited(KaSpotService.flushPendingLocation());
      // Register (or refresh) the FCM token now that we have an authenticated
      // user id to associate it with.
      unawaited(PushNotificationService.initialize());
      // Load existing unread message counts so badges show immediately.
      unawaited(KaSpotService.loadUnreadCounts());
    }
    // Whenever authentication state changes (sign in, sign out, session restore),
    // pop all pushed auth routes back to root so HomeShell or WelcomeScreen is cleanly displayed.
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  void _onRecoveryStateChanged() {
    if (KaSpotService.passwordRecoveryActive.value) {
      if (!_recoveryScreenShown) {
        _recoveryScreenShown = true;
        // A recovery deep link grants a password-reset session only; never
        // route it into the authenticated shell.
        _navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const UpdatePasswordScreen()),
        );
      }
    } else {
      _recoveryScreenShown = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: ocean,
      primary: ocean,
      surface: slateBg,
      brightness: Brightness.light,
    );

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'KaSpot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: slateBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: slateText,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          toolbarHeight: 58,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
            systemNavigationBarColor: Colors.white,
            systemNavigationBarIconBrightness: Brightness.dark,
          ),
          titleTextStyle: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: slateText,
            letterSpacing: -0.5,
          ),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
          ),
          margin: EdgeInsets.zero,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: ocean,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: ocean,
            side: const BorderSide(color: Color(0xFFCBD5E1)),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: ocean, width: 1.8),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          elevation: 0,
          height: 68,
          indicatorColor: const Color(0xFFE0EDFC),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color: selected ? ocean : const Color(0xFF64748B),
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: selected ? ocean : const Color(0xFF64748B),
              size: 24,
            );
          }),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
        ),
      ),
      home: ValueListenableBuilder<bool>(
        valueListenable: KaSpotService.authStateNotifier,
        builder: (context, isAuthenticated, _) {
          return isAuthenticated ? const HomeShell() : const WelcomeScreen();
        },
      ),
    );
  }
}

/// Shown instead of the app when the build's declared backend contradicts the
/// URL it would actually use.
///
/// Deliberately inert: no Supabase client, no Firebase, no location services and
/// no notification service are initialised, because each of those would make a
/// network call against the wrong project before the user could read this. The
/// only way out is to rebuild with a consistent target.
class _MisconfiguredBackendApp extends StatelessWidget {
  const _MisconfiguredBackendApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: KaSpotApp.slateBg,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.report_gmailerrorred_rounded,
                    size: 56,
                    color: KaSpotApp.ocean,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'This build points at the wrong KaSpot backend',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: KaSpotApp.slateText,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: KaSpotApp.mutedText,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Nothing was sent to that backend. Rebuild with '
                    '--dart-define=KASPOT_BACKEND and a matching '
                    '--dart-define=SUPABASE_URL.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: KaSpotApp.mutedText,
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
