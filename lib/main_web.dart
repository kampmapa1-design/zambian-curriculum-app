import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/web_dashboard_home_screen.dart';
import 'theme/app_theme.dart';

/// Separate entry point for the web admin dashboard (School Network
/// Milestone D, added 2026-09-14) — run with
/// `flutter run -d chrome -t lib/main_web.dart`. Deliberately its own
/// `main`, not a `kIsWeb` branch inside the real mobile `main.dart`: the
/// mobile app's home screen pulls in camera/ML Kit/local-PDF plugins that
/// have no Flutter Web support at all, so this entry point only ever
/// imports the Firestore/Firebase-Auth-backed School Network screens —
/// nothing here touches sqflite or any mobile-only plugin.
///
/// Stage 1's "same credentials, same session, no separate registration
/// step" requirement is satisfied for free by reusing [LoginScreen]
/// as-is — it talks only to Firebase Auth/Firestore (the same project,
/// same users, same `schools` collection the mobile app writes to) —
/// there was never a mobile-specific identity to diverge from. Once
/// signed in, [WebDashboardHomeScreen] (not the mobile [SchoolHomeScreen])
/// is the real web-specific home — a persistent sidebar + a live
/// school-wide class board, not a mobile-style list of buttons.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const WebDashboardApp());
}

class WebDashboardApp extends StatelessWidget {
  const WebDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Teacher — Admin',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const _WebAuthGate(),
    );
  }
}

/// Routes purely on real (non-anonymous) sign-in state — this dashboard
/// never auto-bootstraps an anonymous session the way the mobile app does
/// for its AI-gating purpose; an admin either has a real account or sees
/// the sign-in screen, full stop.
class _WebAuthGate extends StatelessWidget {
  const _WebAuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final user = snapshot.data;
        if (user == null || user.isAnonymous) {
          return const LoginScreen();
        }
        return const WebDashboardHomeScreen();
      },
    );
  }
}
