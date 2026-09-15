import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'screens/first_launch_screen.dart';
import 'screens/home_screen.dart';
import 'screens/pupil_home_screen.dart';
import 'services/teacher_profile_repository.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // A widget that throws while building shows Flutter's default
  // ErrorWidget — which in a release build (like every one distributed
  // for testing) is a bare, unlabeled grey box, easily read as "just a
  // blank page" with zero indication anything actually broke. Overriding
  // it (2026-08-31, in response to a real "blank white page" report with
  // no way to reproduce it directly) means the *next* time any screen's
  // build() throws, for any reason, it's immediately visible on-device
  // instead of invisible — turns a silent failure into a diagnosable one.
  ErrorWidget.builder = (FlutterErrorDetails details) => Material(
        color: Colors.white,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Something went wrong showing this screen',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.red)),
                const SizedBox(height: 8),
                Text(details.exceptionAsString(), style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      );

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (error) {
    // The rest of the app is fully offline and doesn't depend on Firebase —
    // only "Teaching notes" generation does. Don't block startup on it,
    // e.g. before `flutterfire configure` has been run (see firebase/README.md).
    debugPrint('Firebase did not initialize: $error');
  }
  // MobileAds.instance.initialize() removed (2026-08-30) — google_mobile_ads
  // was the confirmed cause of a crash-on-launch on a real device. See
  // rewarded_ad_service.dart for the full removal note.
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
      home: const _RoleGate(),
    );
  }
}

/// Home Assignment epic, Stage 1 (added 2026-09-14) — "On first app
/// launch, for any user without an existing account, require phone
/// number entry and a role selection." Gated on the on-device
/// [TeacherProfile.role] rather than FirebaseAuth state: this app has
/// always worked fully offline with only an anonymous session (see
/// AuthService), so "does this install have a role yet" is the real
/// question, not "is this a real account yet" — an account created
/// before this field existed also reads `role: null` and sees the
/// capture flow once, exactly like a brand-new install.
class _RoleGate extends StatefulWidget {
  const _RoleGate();

  @override
  State<_RoleGate> createState() => _RoleGateState();
}

class _RoleGateState extends State<_RoleGate> {
  bool _loading = true;
  AccountRole? _role;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await TeacherProfileRepository().load();
    if (!mounted) return;
    setState(() {
      _role = profile.role;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final role = _role;
    if (role == null) {
      return FirstLaunchScreen(onDone: (chosen) => setState(() => _role = chosen));
    }
    return role == AccountRole.pupil ? const PupilHomeScreen() : const HomeScreen();
  }
}
