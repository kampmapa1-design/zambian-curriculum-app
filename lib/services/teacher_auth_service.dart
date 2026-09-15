import 'package:firebase_auth/firebase_auth.dart';

import 'auth_service.dart';

/// How a teacher's account is currently identified. [anonymous] is the
/// original, still-default state every teacher starts in (see
/// [AuthService]) — [phone] and [email] mean they've gone through
/// [TeacherAuthService] to attach a permanent identity, which the School
/// Code and Staffroom features (not yet built) will require.
enum TeacherLoginMethod { anonymous, phone, email }

TeacherLoginMethod loginMethodOf(User? user) {
  if (user == null) return TeacherLoginMethod.anonymous;
  if (user.isAnonymous) return TeacherLoginMethod.anonymous;
  for (final info in user.providerData) {
    if (info.providerId == 'phone') return TeacherLoginMethod.phone;
    if (info.providerId == 'password') return TeacherLoginMethod.email;
  }
  return TeacherLoginMethod.anonymous;
}

/// A friendly, already-worded error for the login/account screens to show
/// directly — never a raw FirebaseAuthException code.
class TeacherAuthError implements Exception {
  final String message;
  const TeacherAuthError(this.message);
  @override
  String toString() => message;
}

/// Result of a completed phone-code or email sign-in/sign-up, so the
/// caller can tell the teacher whether their prior anonymous data (marking
/// history, lesson progress) actually carried over.
class TeacherAuthResult {
  final User user;
  final bool upgradedFromAnonymous;
  const TeacherAuthResult({required this.user, required this.upgradedFromAnonymous});
}

/// Real sign-up/sign-in for a teacher, on top of the anonymous session
/// [AuthService] already guarantees exists. Two paths — phone OTP and
/// email/password — both converging on the same authenticated [User]
/// afterwards; nothing downstream needs to know which one was used (per
/// explicit request). Whenever the app's *current* user is still
/// anonymous, both paths use `linkWithCredential` first so the teacher
/// keeps their existing UID (and therefore their existing on-device
/// marking history / lesson progress / teacher profile, all of which are
/// keyed to nothing but "this device's current install" today) rather than
/// starting a fresh identity.
class TeacherAuthService {
  TeacherAuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  bool get isAnonymous => _auth.currentUser?.isAnonymous ?? true;
  User? get currentUser => _auth.currentUser;
  TeacherLoginMethod get currentLoginMethod => loginMethodOf(_auth.currentUser);

  // ---------------------------------------------------------------------
  // Phone
  // ---------------------------------------------------------------------

  /// Starts phone verification. [onCodeSent] receives the verificationId to
  /// hand back to [confirmPhoneCode]. On some Android devices Firebase can
  /// auto-verify the code without the teacher typing anything — when that
  /// happens [onAutoVerified] fires with the finished result instead.
  Future<void> startPhoneVerification({
    required String phoneNumber,
    required void Function(String verificationId) onCodeSent,
    required void Function(TeacherAuthError error) onError,
    void Function(TeacherAuthResult result)? onAutoVerified,
  }) async {
    await AuthService.instance.ensureSignedIn();
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential credential) async {
        if (onAutoVerified == null) return;
        try {
          final result = await _completeWithCredential(credential);
          onAutoVerified(result);
        } on TeacherAuthError catch (e) {
          onError(e);
        }
      },
      verificationFailed: (FirebaseAuthException e) => onError(_mapAuthException(e)),
      codeSent: (String verificationId, int? resendToken) => onCodeSent(verificationId),
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  /// Confirms the SMS code the teacher typed in and links/signs in with it.
  Future<TeacherAuthResult> confirmPhoneCode({
    required String verificationId,
    required String smsCode,
  }) async {
    final credential = PhoneAuthProvider.credential(verificationId: verificationId, smsCode: smsCode);
    return _completeWithCredential(credential);
  }

  // ---------------------------------------------------------------------
  // Email
  // ---------------------------------------------------------------------

  Future<TeacherAuthResult> signUpWithEmail({required String email, required String password}) async {
    await AuthService.instance.ensureSignedIn();
    final credential = EmailAuthProvider.credential(email: email.trim(), password: password);
    try {
      return await _completeWithCredential(credential);
    } on TeacherAuthError catch (e) {
      // The email is already a real account elsewhere — fall back to
      // signing into THAT account rather than failing outright. The
      // teacher's anonymous data on this device does not carry over in
      // this one case (there's no existing UID to link into); the caller
      // shows this plainly rather than pretending it merged.
      if (e.message.contains('already registered')) {
        final result = await signInWithEmail(email: email, password: password);
        return TeacherAuthResult(user: result.user, upgradedFromAnonymous: false);
      }
      rethrow;
    }
  }

  Future<TeacherAuthResult> signInWithEmail({required String email, required String password}) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(email: email.trim(), password: password);
      final user = credential.user;
      if (user == null) throw const TeacherAuthError('Sign-in did not return an account.');
      return TeacherAuthResult(user: user, upgradedFromAnonymous: false);
    } on FirebaseAuthException catch (e) {
      throw _mapAuthException(e);
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw _mapAuthException(e);
    }
  }

  // ---------------------------------------------------------------------
  // Change phone number (Stage 6 — from Account Settings, once already
  // signed in with a phone number). Re-verifies the new number with a
  // fresh OTP, same as first-time sign-up, then swaps the credential on
  // the existing (already-permanent) account — the UID never changes.
  // ---------------------------------------------------------------------

  Future<void> startPhoneNumberChange({
    required String newPhoneNumber,
    required void Function(String verificationId) onCodeSent,
    required void Function(TeacherAuthError error) onError,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: newPhoneNumber,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (_) {},
      verificationFailed: (FirebaseAuthException e) => onError(_mapAuthException(e)),
      codeSent: (String verificationId, int? resendToken) => onCodeSent(verificationId),
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  Future<void> confirmPhoneNumberChange({required String verificationId, required String smsCode}) async {
    final user = _auth.currentUser;
    if (user == null) throw const TeacherAuthError('You are not signed in.');
    final credential = PhoneAuthProvider.credential(verificationId: verificationId, smsCode: smsCode);
    try {
      await user.updatePhoneNumber(credential);
    } on FirebaseAuthException catch (e) {
      throw _mapAuthException(e);
    }
  }

  Future<void> signOut() => _auth.signOut();

  // ---------------------------------------------------------------------

  Future<TeacherAuthResult> _completeWithCredential(AuthCredential credential) async {
    final current = _auth.currentUser;
    try {
      if (current != null && current.isAnonymous) {
        // Preserve the existing UID — marking history, lesson progress,
        // and teacher profile already tied to this device's anonymous
        // session carry straight over (per explicit request).
        final result = await current.linkWithCredential(credential);
        final user = result.user;
        if (user == null) throw const TeacherAuthError('Could not finish creating your account.');
        return TeacherAuthResult(user: user, upgradedFromAnonymous: true);
      }
      final result = await _auth.signInWithCredential(credential);
      final user = result.user;
      if (user == null) throw const TeacherAuthError('Could not finish signing in.');
      return TeacherAuthResult(user: user, upgradedFromAnonymous: false);
    } on FirebaseAuthException catch (e) {
      throw _mapAuthException(e);
    }
  }

  TeacherAuthError _mapAuthException(FirebaseAuthException e) {
    switch (e.code) {
      case 'credential-already-in-use':
      case 'email-already-in-use':
        return const TeacherAuthError('This is already registered. Signing you into that account instead.');
      case 'invalid-verification-code':
        return const TeacherAuthError('That code is incorrect. Check the SMS and try again.');
      case 'invalid-phone-number':
        return const TeacherAuthError('That phone number does not look right. Include the country code, e.g. +260...');
      case 'weak-password':
        return const TeacherAuthError('Choose a stronger password (at least 6 characters).');
      case 'wrong-password':
      case 'invalid-credential':
        return const TeacherAuthError('Incorrect email or password.');
      case 'user-not-found':
        return const TeacherAuthError('No account found for that email. Try signing up instead.');
      case 'too-many-requests':
        return const TeacherAuthError('Too many attempts. Wait a moment and try again.');
      case 'network-request-failed':
        return const TeacherAuthError("You're offline. Connect to the internet and try again.");
      case 'quota-exceeded':
        return const TeacherAuthError('SMS verification is temporarily unavailable. Try again later.');
      default:
        return TeacherAuthError(e.message ?? 'Something went wrong (${e.code}).');
    }
  }
}
