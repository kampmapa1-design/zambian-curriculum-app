import 'package:firebase_auth/firebase_auth.dart';

/// Ensures the app has an anonymous Firebase Auth session before calling any
/// auth-gated Cloud Function. Anonymous auth is enough to keep unauthenticated
/// callers off the Anthropic API key/budget behind `generateTeachingNotes` —
/// see firebase/README.md for what this does and doesn't protect against.
class AuthService {
  AuthService._internal();
  static final AuthService instance = AuthService._internal();

  Future<User> ensureSignedIn() async {
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
