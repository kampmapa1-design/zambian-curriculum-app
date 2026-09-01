import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

/// Thrown for "can't reach the function" (offline), "the function rejected
/// the request" (e.g. attachments too large, invalid email), and any
/// response that doesn't match the expected shape.
class AssignmentSubmissionEmailUnavailable implements Exception {
  final String message;
  const AssignmentSubmissionEmailUnavailable(this.message);
  @override
  String toString() => message;
}

/// Real, automatic email sending for Assignment Submission's Stage 8 —
/// calls the `sendAssignmentSubmissionEmail` Cloud Function, which hands
/// the PDF (and image bundle, if it fits) to Resend (resend.com), a
/// third-party transactional email API. Unlike the WhatsApp path
/// elsewhere in this feature, this genuinely needs no further tap once
/// called: the student's teacher receives the email directly.
///
/// Shared verbatim with Test Submission (2026-09-02, see that feature's
/// Stage 7: "reuse Assignment Submission's transmission logic exactly")
/// via the [submissionKind] parameter on [send] — still named for
/// Assignment Submission since that's what it was built for first.
class AssignmentSubmissionEmailService {
  AssignmentSubmissionEmailService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// Sends [pdfFile] (and [imageBundleFile], if given) to [recipientEmail].
  /// [assignmentTitle] is just the title line shown in the email body —
  /// for a non-'assignment' [submissionKind] (e.g. Test Submission passes
  /// 'test'), pass whatever title fits that context (e.g. the subject
  /// name). Returns the provider's message id on success (may be empty).
  Future<String> send({
    required String recipientEmail,
    required String studentName,
    required String assignmentTitle,
    required String submissionHash,
    required DateTime submittedAt,
    required File pdfFile,
    required String pdfFileName,
    File? imageBundleFile,
    String? imageBundleFileName,
    String submissionKind = 'assignment',
  }) async {
    var lastStatus = 'starting';
    void track(String status) => lastStatus = status;

    try {
      return await _run(
        recipientEmail: recipientEmail,
        studentName: studentName,
        assignmentTitle: assignmentTitle,
        submissionHash: submissionHash,
        submittedAt: submittedAt,
        pdfFile: pdfFile,
        pdfFileName: pdfFileName,
        imageBundleFile: imageBundleFile,
        imageBundleFileName: imageBundleFileName,
        submissionKind: submissionKind,
        onProgress: track,
      ).timeout(
        const Duration(seconds: 175),
        onTimeout: () => throw AssignmentSubmissionEmailUnavailable(
          'Sending the email is taking too long and may be stuck (last step: "$lastStatus"). Check your '
          'connection and try again, or use the WhatsApp option instead.',
        ),
      );
    } on AssignmentSubmissionEmailUnavailable {
      rethrow;
    } catch (error) {
      throw AssignmentSubmissionEmailUnavailable('Could not send the email (last step: "$lastStatus"): $error');
    }
  }

  Future<String> _run({
    required String recipientEmail,
    required String studentName,
    required String assignmentTitle,
    required String submissionHash,
    required DateTime submittedAt,
    required File pdfFile,
    required String pdfFileName,
    required File? imageBundleFile,
    required String? imageBundleFileName,
    required String submissionKind,
    required void Function(String status) onProgress,
  }) async {
    onProgress('Checking connection…');
    if (!await isOnline) {
      throw const AssignmentSubmissionEmailUnavailable("You're offline. Connect to the internet to email your teacher.");
    }

    onProgress('Signing in…');
    await AuthService.instance.ensureSignedIn();

    onProgress('Preparing the submission…');
    final pdfBase64 = base64Encode(await pdfFile.readAsBytes());
    final imageBundleBase64 = imageBundleFile != null ? base64Encode(await imageBundleFile.readAsBytes()) : null;

    final callable = _functions.httpsCallable(
      'sendAssignmentSubmissionEmail',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 170)),
    );

    onProgress('Sending the email…');
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'recipientEmail': recipientEmail,
        'studentName': studentName,
        'assignmentTitle': assignmentTitle,
        'submissionHash': submissionHash,
        'submittedAt': submittedAt.toIso8601String(),
        'pdfBase64': pdfBase64,
        'pdfFileName': pdfFileName,
        if (imageBundleBase64 != null) 'imageBundleBase64': imageBundleBase64,
        if (imageBundleFileName != null) 'imageBundleFileName': imageBundleFileName,
        'submissionKind': submissionKind,
      });
      final messageId = result.data['messageId'];
      return messageId is String ? messageId : '';
    } on FirebaseFunctionsException catch (e) {
      throw AssignmentSubmissionEmailUnavailable(e.message ?? 'Failed to send the email.');
    }
  }
}
