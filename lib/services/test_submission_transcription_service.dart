import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/test_submission.dart';
import 'auth_service.dart';

class TranscribedTestSubmission {
  final List<TestAnswerSegment> segments;
  final String notes;

  const TranscribedTestSubmission({required this.segments, required this.notes});

  factory TranscribedTestSubmission.fromMap(Map<Object?, Object?> map) {
    final segmentsRaw = (map['segments'] as List?) ?? const [];
    return TranscribedTestSubmission(
      segments: [
        for (final s in segmentsRaw)
          if (s is Map)
            TestAnswerSegment(
              questionNumber: s['questionNumber'] as String? ?? 'Unlabeled',
              text: s['text'] as String? ?? '',
            ),
      ],
      notes: map['notes'] as String? ?? '',
    );
  }
}

class TestSubmissionTranscriptionUnavailable implements Exception {
  final String message;
  const TestSubmissionTranscriptionUnavailable(this.message);
  @override
  String toString() => message;
}

/// Test Submission, Stage 3 — calls the `transcribeTestSubmission` Cloud
/// Function, which detects handwritten question-number markers and
/// structures the transcription by detected question.
class TestSubmissionTranscriptionService {
  TestSubmissionTranscriptionService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<TranscribedTestSubmission> transcribe(List<File> pageFiles) async {
    var lastStatus = 'starting';
    void track(String status) => lastStatus = status;

    try {
      return await _run(pageFiles, track).timeout(
        const Duration(seconds: 110),
        onTimeout: () => throw TestSubmissionTranscriptionUnavailable(
          'This is taking too long and may be stuck (last step: "$lastStatus"). Check your connection and try again.',
        ),
      );
    } on TestSubmissionTranscriptionUnavailable {
      rethrow;
    } catch (error) {
      throw TestSubmissionTranscriptionUnavailable('Could not transcribe this test (last step: "$lastStatus"): $error');
    }
  }

  Future<TranscribedTestSubmission> _run(List<File> pageFiles, void Function(String status) onProgress) async {
    onProgress('Checking connection…');
    if (!await isOnline) {
      throw const TestSubmissionTranscriptionUnavailable("You're offline. Connect to the internet to transcribe this test.");
    }

    onProgress('Signing in…');
    await AuthService.instance.ensureSignedIn();

    onProgress('Preparing pages…');
    final images = <String>[];
    for (final file in pageFiles) {
      images.add(base64Encode(await file.readAsBytes()));
    }

    final callable = _functions.httpsCallable(
      'transcribeTestSubmission',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 100)),
    );

    onProgress('Reading the answers with AI…');
    try {
      final result = await callable.call<Map<Object?, Object?>>({'pageImagesBase64': images});
      return TranscribedTestSubmission.fromMap(result.data);
    } on FirebaseFunctionsException catch (e) {
      throw TestSubmissionTranscriptionUnavailable(e.message ?? 'Failed to transcribe this test.');
    }
  }
}
