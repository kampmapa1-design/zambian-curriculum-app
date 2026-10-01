import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'screens/first_launch_screen.dart';
import 'models/marking_credits.dart';
import 'screens/home_screen.dart';
import 'screens/marking_credits_screen.dart';
import 'screens/pupil_home_screen.dart';
import 'services/metered_call.dart';
import 'services/teacher_profile_repository.dart';
import 'theme/app_theme.dart';

/// The last real Firebase startup error, if initialization ultimately
/// failed (null when it succeeded) — appended to the on-screen error
/// widget below so a "[core/no-app]" report says WHY, not just that.
String? firebaseInitError;

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
                Text('Something went wrong showing this screen',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.red.shade700)),
                const SizedBox(height: 8),
                Text(details.exceptionAsString(), style: const TextStyle(fontSize: 12)),
                if (firebaseInitError != null) ...[
                  const SizedBox(height: 8),
                  Text('Startup error: $firebaseInitError', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                ],
              ],
            ),
          ),
        ),
      );

  try {
    // A transient failure at cold start (seen on real devices right after
    // an install/update) used to be swallowed after one attempt, leaving
    // the whole session with no Firebase app — every Firebase-touching
    // screen then failed with "[core/no-app]". Retry a couple of times
    // before giving up, and keep the last real error so it can be shown.
    Object? lastInitError;
    for (var attempt = 0; attempt < 3 && Firebase.apps.isEmpty; attempt++) {
      try {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      } catch (error) {
        lastInitError = error;
        firebaseInitError = '$error';
        debugPrint('Firebase init attempt ${attempt + 1} failed: $error');
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
    if (Firebase.apps.isEmpty) throw lastInitError ?? StateError('Firebase.apps is empty after init');
    firebaseInitError = null;
    // App Check (added 2026-09-18) — activated right after Firebase itself
    // and before any other Firebase service call, so every Cloud Functions
    // call after this point carries an App Check token automatically (the
    // cloud_functions plugin attaches it on its own — no per-call code).
    // Release builds attest via Play Integrity; debug builds use App
    // Check's debug provider (the SDK prints a debug token to logcat on
    // first run — register it in Firebase Console > App Check > the app's
    // "Manage debug tokens" so local development keeps working once
    // enforcement is on). Its own try/catch, deliberately: an attestation
    // failure (no Play Services, no network at first launch, Console not
    // set up yet) must never block startup — and while the server-side
    // enforcement switch is still off (see APP_CHECK_ENFORCED in
    // firebase/functions/src/index.ts), a missing token costs nothing.
    // Enforcement itself is a separate, deliberate later step; this is
    // only the client half.
    try {
      await FirebaseAppCheck.instance.activate(
        androidProvider: kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
      );
    } catch (error) {
      debugPrint('Firebase App Check did not activate: $error');
    }
    // Crashlytics REMOVED (2026-09-28, circuit-breaker) — real, reported
    // bug: `Firebase.initializeApp()` itself was throwing a native
    // `NullPointerException: FirebaseCrashlytics component is not
    // present` on a real device, deterministically, blocking every
    // single Firebase-dependent feature in the app (marking, lesson
    // plans, past papers, home assignment — everything). This happened
    // even on the very FIRST, only initialization attempt, ruling out
    // "called too many times" as the cause — something about this
    // device's Crashlytics component registration is broken at a level
    // no amount of client-side retry logic can fix. Removing the
    // Crashlytics plugin/dependency entirely (see pubspec.yaml,
    // android/build.gradle.kts, android/app/build.gradle.kts) is the
    // most direct way to find out whether Crashlytics itself is really
    // the culprit — if every other Firebase feature starts working once
    // it's gone, that confirms it; if not, the search continues
    // elsewhere. Real, disclosed cost: no crash reporting until this is
    // re-added (once a working, or at least non-fatal-to-startup,
    // Crashlytics setup is found).
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

/// Lets the out-of-credits dialog be shown from anywhere (see [OutOfCreditsNotifier]).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class CurriculumApp extends StatefulWidget {
  const CurriculumApp({super.key});

  @override
  State<CurriculumApp> createState() => _CurriculumAppState();
}

class _CurriculumAppState extends State<CurriculumApp> {
  StreamSubscription<InsufficientCreditsException>? _outOfCredits;

  @override
  void initState() {
    super.initState();
    // Any metered AI feature that is refused for lack of credits raises ONE
    // explanatory dialog here, whichever screen it came from.
    _outOfCredits = OutOfCreditsNotifier.instance.stream.listen((reason) {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null && ctx.mounted) showOutOfCreditsDialog(ctx, reason);
    });
  }

  @override
  void dispose() {
    _outOfCredits?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Smart Teacher',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const _RoleGate(),
    );
  }
}

/// Home Assignment epic, Stage 1 (added 2026-09-14; revised 2026-09-17
/// per explicit request — "once a user logs on as a learner, the app
/// interface continues to open with the learner facing interface
/// instead of giving the page where everyone can choose"). Originally
/// this only showed [FirstLaunchScreen] once, on the very first launch,
/// then remembered [TeacherProfile.role] forever and skipped straight
/// to [PupilHomeScreen]/[HomeScreen] on every later open — a real
/// problem on a shared device (a parent and child, or a classroom
/// computer used by both teachers and pupils), where the SAME install
/// would only ever offer one role once it had been picked. Now every
/// launch shows the role choice again; the previously-saved role is
/// only used to pre-select an option for convenience (see
/// [FirstLaunchScreen]'s `initialRole`), never to skip the screen
/// outright. Real sign-in state (Firebase Auth, School Network
/// membership) is untouched by this — picking the same role again just
/// re-enters the same already-signed-in account, nothing is reset.
class _RoleGate extends StatefulWidget {
  const _RoleGate();

  @override
  State<_RoleGate> createState() => _RoleGateState();
}

class _RoleGateState extends State<_RoleGate> {
  bool _loading = true;
  AccountRole? _savedRole;
  AccountRole? _confirmedRole;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await TeacherProfileRepository().load();
    if (!mounted) return;
    setState(() {
      _savedRole = profile.role;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final confirmed = _confirmedRole;
    if (confirmed == null) {
      return FirstLaunchScreen(initialRole: _savedRole, onDone: (chosen) => setState(() => _confirmedRole = chosen));
    }
    return confirmed == AccountRole.pupil ? const PupilHomeScreen() : const HomeScreen();
  }
}
