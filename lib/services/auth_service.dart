import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../firebase_options.dart';

/// Thrown by [AuthService.ensureSignedIn] in place of the raw
/// `[core/no-app]` platform exception — every one of the 25+ AI/cloud
/// services that call this first show whatever this throws directly to the
/// teacher on failure, and "No Firebase App '[DEFAULT]' has been created -
/// call Firebase.initializeApp()" means nothing to them.
class FirebaseUnavailableException implements Exception {
  final String message;

  /// The real platform error behind this, when one was actually caught
  /// (vs. `Firebase.apps` just still being empty with no exception at
  /// all). Real, reported gap (2026-09-28): every occurrence of this
  /// exception so far has shown the teacher/Claude only this class's own
  /// generic wording — the ACTUAL reason `Firebase.initializeApp()` kept
  /// failing has never once been visible outside a debug console, making
  /// a real recurring failure impossible to root-cause from a screenshot
  /// alone. Appended to [message] (truncated) so the next report carries it.
  final Object? cause;

  const FirebaseUnavailableException([this.cause])
      : message = "Couldn't reach this app's online services. Please fully close and reopen the app, then try again.";

  @override
  String toString() {
    if (cause == null) return message;
    // Real, reported case (2026-09-28): the first real capture this ever
    // produced was a native PlatformException/ExecutionException/
    // NullPointerException chain from Firebase.initializeApp() itself —
    // genuinely not a network problem, a real Android-side SDK failure —
    // and it got cut off mid-word at 160 chars, before the actually
    // diagnostic part (the innermost exception/class) was visible. Widened
    // substantially; this is diagnostic text shown once in a dialog, not
    // something that needs to stay short.
    final causeText = '$cause';
    return '$message (${causeText.length > 1000 ? causeText.substring(0, 1000) : causeText})';
  }
}

/// Ensures the app has an anonymous Firebase Auth session before calling any
/// auth-gated Cloud Function. Anonymous auth is enough to keep unauthenticated
/// callers off the AI provider's API key/budget behind `generateTeachingNotes`
/// (Gemini as of 2026-08-26, Anthropic before/after — see that function's own
/// comment in firebase/functions/src/index.ts for which is currently active) —
/// see firebase/README.md for what this does and doesn't protect against.
class AuthService {
  AuthService._internal();
  static final AuthService instance = AuthService._internal();

  /// Real root cause found 2026-09-28, from an actual captured platform
  /// exception (see [FirebaseUnavailableException.cause]'s own doc): a
  /// native `NullPointerException: FirebaseCrashlytics component is not
  /// present` thrown from deep inside `Firebase.initializeApp()`'s own
  /// call chain — not a network problem at all. The lazy retry below used
  /// to re-run its own up-to-3-attempt `Firebase.initializeApp()` cycle
  /// EVERY time `ensureSignedIn()` was called while `Firebase.apps` was
  /// still empty — i.e. once per distinct online feature a teacher tried
  /// during a session stuck in this state, not just once. Repeatedly
  /// re-calling `Firebase.initializeApp()` for the default app across a
  /// session is exactly the kind of thing that can leave the native SDK's
  /// one-time Crashlytics component registration in a broken state.
  /// Capped to ONE lazy attempt cycle per app process — if it fails, every
  /// later call this same session fails fast with the same recorded cause
  /// instead of hammering native init again; a fresh attempt only ever
  /// happens on the next real app restart, matching the error message's
  /// own "close and reopen the app" advice.
  static bool _lazyInitAttempted = false;
  static Object? _lazyInitFailure;

  Future<User> ensureSignedIn() async {
    if (Firebase.apps.isEmpty) {
      if (_lazyInitAttempted) {
        throw FirebaseUnavailableException(_lazyInitFailure);
      }
      _lazyInitAttempted = true;
      Object? lastInitError;
      for (var attempt = 0; attempt < 3 && Firebase.apps.isEmpty; attempt++) {
        try {
          await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
        } catch (error) {
          lastInitError = error;
          if (attempt < 2) await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      if (Firebase.apps.isEmpty) {
        _lazyInitFailure = lastInitError;
        throw FirebaseUnavailableException(lastInitError);
      }
    }

    // Everything past this point is unchanged from before this fix — a
    // real FirebaseAuthException (e.g. anonymous auth disabled in the
    // Console, rate-limited) still propagates with its own real message,
    // since that's an actionable, different problem from "Firebase never
    // came up", and callers already display it as-is.
    final auth = FirebaseAuth.instance;
    final current = auth.currentUser;
    if (current != null) return current;

    final credential = await auth.signInAnonymously();
    final user = credential.user;
    if (user == null) {
      throw StateError('Anonymous sign-in did not return a user.');
    }
    return user;
  }
}
