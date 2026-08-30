import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (error) {
    // The rest of the app is fully offline and doesn't depend on Firebase —
    // only "Teaching notes" generation does. Don't block startup on it,
    // e.g. before `flutterfire configure` has been run (see firebase/README.md).
    debugPrint('Firebase did not initialize: $error');
  }
  try {
    // Admin Tools ad-gate (Word/PDF converter, Minutes Maker) — see
    // RewardedAdService. Same non-blocking pattern as Firebase above: an
    // ad SDK that fails to initialize (offline at first launch, etc.)
    // shouldn't take the rest of the app down with it.
    await MobileAds.instance.initialize();
  } catch (error) {
    debugPrint('Mobile Ads SDK did not initialize: $error');
  }
  runApp(const CurriculumApp());
}

class CurriculumApp extends StatelessWidget {
  const CurriculumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Teacher',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
