import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // After running `flutterfire configure` (see firebase/README.md), switch
    // this to `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`
    // using the generated lib/firebase_options.dart — more robust than
    // relying on native config-file auto-detection, especially on iOS.
    await Firebase.initializeApp();
  } catch (error) {
    // The rest of the app is fully offline and doesn't depend on Firebase —
    // only "Teaching notes" generation does. Don't block startup on it,
    // e.g. before `flutterfire configure` has been run (see firebase/README.md).
    debugPrint('Firebase did not initialize: $error');
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
