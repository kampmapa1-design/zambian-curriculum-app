import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/teacher_submission.dart';
import 'auth_service.dart';

class TeacherDashboardUnavailable implements Exception {
  final String message;
  const TeacherDashboardUnavailable(this.message);
  @override
  String toString() => message;
}

/// One file to upload to the Dashboard.
class DashboardUploadFile {
  final File file;
  final String filename;
  final String contentType;
  const DashboardUploadFile({required this.file, required this.filename, required this.contentType});
}

/// Teacher Submissions Dashboard (Stage 11) — client side of the
/// "lightweight cloud mailbox" model. See the four Cloud Functions this
/// wraps (`requestDashboardAccessCode`, `verifyDashboardAccessCode`,
/// `submitToTeacherDashboard`, `getSubmissionFileUrl`) for the real
/// security model; this class is a thin, honest wrapper — it never
/// reads/writes Firestore or Storage directly except the one `.where`
/// query in [listSubmissions], which Firestore's own security rules
/// still enforce against the caller's verified claim.
class TeacherDashboardService {
  TeacherDashboardService({FirebaseFunctions? functions, FirebaseFirestore? firestore})
      : _functions = functions ?? FirebaseFunctions.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;

  static const _verifiedEmailPrefsKey = 'dashboard_verified_teacher_email';

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// The email this device is currently verified for, or null if none —
  /// remembered locally (SharedPreferences) so the one-time code isn't
  /// needed on every app open. Does NOT re-check the server; a revoked/
  /// expired claim just surfaces as a permission error on the next real
  /// Firestore read, at which point the caller should call [signOutOfDashboard].
  Future<String?> verifiedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_verifiedEmailPrefsKey);
  }

  Future<void> signOutOfDashboard() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_verifiedEmailPrefsKey);
  }

  Future<void> requestAccessCode(String email) async {
    if (!await isOnline) {
      throw const TeacherDashboardUnavailable("You're offline. Connect to the internet to request a code.");
    }
    await AuthService.instance.ensureSignedIn();
    final callable = _functions.httpsCallable('requestDashboardAccessCode');
    try {
      await callable.call<Map<Object?, Object?>>({'email': email.trim()});
    } on FirebaseFunctionsException catch (e) {
      throw TeacherDashboardUnavailable(e.message ?? 'Could not send the access code.');
    }
  }

  /// Verifies [code] for [email]; on success, stamps the `teacherEmail`
  /// custom claim (server-side) and force-refreshes this device's ID
  /// token so it takes effect immediately, then remembers [email]
  /// locally so [verifiedEmail] returns it on future launches.
  Future<void> verifyAccessCode({required String email, required String code}) async {
    if (!await isOnline) {
      throw const TeacherDashboardUnavailable("You're offline. Connect to the internet to verify.");
    }
    await AuthService.instance.ensureSignedIn();
    final callable = _functions.httpsCallable('verifyDashboardAccessCode');
    try {
      await callable.call<Map<Object?, Object?>>({'email': email.trim(), 'code': code.trim()});
    } on FirebaseFunctionsException catch (e) {
      throw TeacherDashboardUnavailable(e.message ?? 'That code did not verify.');
    }

    // The custom claim was just set server-side — force a refresh so this
    // device's cached ID token (and therefore every Firestore rule check
    // from here on) actually carries it. Without `true` here the SDK
    // would keep using the stale, pre-verification token until it
    // naturally expires (up to an hour).
    await FirebaseAuth.instance.currentUser?.getIdTokenResult(true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_verifiedEmailPrefsKey, email.trim().toLowerCase());
  }

  /// Stage 8's transmission, extended (2026-09-02): called right after a
  /// successful (or attempted) email send, only when a teacher email was
  /// entered — that address is the only thing that ties a submission to
  /// a mailbox. Best-effort by design: a caller should not block or fail
  /// the student's actual submission over this — see both submission
  /// screens' `_send()` for how failures here are swallowed, never shown
  /// as an error on top of a real, successful send.
  Future<void> submitToDashboard({
    required String teacherEmail,
    required SubmissionKind kind,
    required String studentName,
    required String className,
    required String subjectName,
    required String title,
    required DateTime submittedAt,
    required String sha256Hash,
    required String referenceInfo,
    required List<DashboardUploadFile> attachments,
  }) async {
    if (!await isOnline) return;
    await AuthService.instance.ensureSignedIn();
    final callable = _functions.httpsCallable(
      'submitToTeacherDashboard',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 100)),
    );
    final encoded = [
      for (final a in attachments)
        {
          'filename': a.filename,
          'contentType': a.contentType,
          'base64': base64Encode(await a.file.readAsBytes()),
        },
    ];
    await callable.call<Map<Object?, Object?>>({
      'teacherEmail': teacherEmail.trim(),
      'kind': kind.name,
      'studentName': studentName,
      'className': className,
      'subjectName': subjectName,
      'title': title,
      'submittedAt': submittedAt.toIso8601String(),
      'sha256Hash': sha256Hash,
      'referenceInfo': referenceInfo,
      'attachments': encoded,
    });
  }

  /// All submissions addressed to [teacherEmail] — requires this device
  /// to already be verified for that email (see [verifyAccessCode]);
  /// Firestore's own security rules reject the query otherwise.
  Future<List<TeacherSubmission>> listSubmissions(String teacherEmail) async {
    await AuthService.instance.ensureSignedIn();
    try {
      final snap = await _firestore
          .collection('submissions')
          .where('teacherEmail', isEqualTo: teacherEmail.trim().toLowerCase())
          .orderBy('submittedAt', descending: true)
          .get();
      return snap.docs.map(TeacherSubmission.fromDoc).toList();
    } on FirebaseException catch (e) {
      throw TeacherDashboardUnavailable(e.message ?? 'Could not load the Dashboard.');
    }
  }

  /// A fresh, short-lived download URL for one of [submission]'s files —
  /// requested on demand rather than stored, so it never goes stale.
  Future<String> fileUrl(TeacherSubmission submission, SubmissionFile file) async {
    if (!await isOnline) {
      throw const TeacherDashboardUnavailable("You're offline. Connect to the internet to open this file.");
    }
    final callable = _functions.httpsCallable('getSubmissionFileUrl');
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'submissionId': submission.id,
        'storagePath': file.storagePath,
      });
      final url = result.data['url'];
      if (url is! String) throw const TeacherDashboardUnavailable('The download link came back empty.');
      return url;
    } on FirebaseFunctionsException catch (e) {
      throw TeacherDashboardUnavailable(e.message ?? 'Could not open this file.');
    }
  }
}
