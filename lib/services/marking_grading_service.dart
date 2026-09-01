import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import 'auth_service.dart';

/// [MarkingGradingService.grade]'s result — the per-question answers plus
/// the 3-5 script-level performance observations, kept together since
/// they come from the same Cloud Function call and are stored together
/// on [MarkingScript].
class MarkingGradingResult {
  final List<GradedAnswer> answers;
  final List<String> observations;

  const MarkingGradingResult({required this.answers, required this.observations});
}

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request" — either way there's a user-facing message and a
/// script to leave in [MarkingScriptStatus.needsRetry] (Stage 8).
class MarkingGradingUnavailable implements Exception {
  final String message;
  const MarkingGradingUnavailable(this.message);
  @override
  String toString() => message;
}

/// AI-Assisted Marking, Stage 4 — calls the `gradeMarkingScript` Cloud
/// Function with one script's page images and its linked scheme's
/// questions, returning a [GradedAnswer] per question. Needs a live
/// connection; every answer returned is a first-pass AI suggestion, never
/// a final mark (Stage 6 requires teacher review before anything is
/// final).
class MarkingGradingService {
  MarkingGradingService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<MarkingGradingResult> grade({
    required List<File> pageFiles,
    required MarkingScheme scheme,
    List<PreSegmentedAnswer>? preSegmentedAnswers,
  }) async {
    // Hard backstop covering EVERYTHING, including the connectivity check
    // itself — see HandwrittenListTranscriptionService.transcribe for the
    // full reasoning: a connectivity-plugin call that stalls ahead of the
    // timeout wrapper defeats it entirely, so nothing runs outside this.
    try {
      return await _doGrade(pageFiles, scheme, preSegmentedAnswers).timeout(
        const Duration(seconds: 200),
        onTimeout: () => throw const MarkingGradingUnavailable(
          'Grading this script is taking too long and may be stuck. Check your connection and try again.',
        ),
      );
    } on MarkingGradingUnavailable {
      rethrow;
    } catch (error) {
      throw MarkingGradingUnavailable('Could not grade this script: $error');
    }
  }

  Future<MarkingGradingResult> _doGrade(
    List<File> pageFiles,
    MarkingScheme scheme,
    List<PreSegmentedAnswer>? preSegmentedAnswers,
  ) async {
    if (!await isOnline) {
      throw const MarkingGradingUnavailable("You're offline. Connect to the internet to grade this script.");
    }
    await AuthService.instance.ensureSignedIn();

    final pageImagesBase64 = [
      for (final file in pageFiles) base64Encode(await file.readAsBytes()),
    ];

    final callable = _functions.httpsCallable(
      'gradeMarkingScript',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 170)),
    );

    Object? rawData;
    try {
      final result = await callable.call<Object?>({
        'pageImagesBase64': pageImagesBase64,
        'questions': [
          for (final q in scheme.questions)
            {
              'label': q.label,
              'expectedAnswerOrKeywords': q.expectedAnswerOrKeywords,
              'maxMarks': q.maxMarks,
            },
        ],
        if (preSegmentedAnswers != null && preSegmentedAnswers.isNotEmpty)
          'preSegmentedAnswers': [for (final s in preSegmentedAnswers) s.toJson()],
      });
      rawData = result.data;
    } on FirebaseFunctionsException catch (e) {
      throw MarkingGradingUnavailable(e.message ?? 'Failed to grade this script.');
    }

    // Defensive from here on — `is` checks rather than blind casts, so a
    // response that doesn't match the expected shape produces a clear
    // message (and a normal needsRetry, via runBatchGrading's own
    // catch) instead of a raw Dart TypeError. See
    // HandwrittenListTranscriptionService.transcribe for the same pattern and
    // the bug it was added to fix.
    if (rawData is! Map) {
      throw const MarkingGradingUnavailable('The grading response was in an unexpected format.');
    }
    final responseData = rawData;
    final answersRaw = responseData['answers'];
    if (answersRaw is! List) {
      throw const MarkingGradingUnavailable('The grading response was in an unexpected format.');
    }

    final byLabel = <String, Map>{};
    for (final a in answersRaw) {
      if (a is! Map) continue;
      final label = a['questionLabel'];
      if (label is String) byLabel[label] = a;
    }

    // Built from the scheme's own question list, not just whatever the
    // AI returned — a question the AI skipped still shows up (as
    // low-confidence/zero marks) rather than silently vanishing from
    // the review screen.
    final answers = [
      for (final q in scheme.questions)
        if (byLabel[q.label] case final a?)
          GradedAnswer(
            questionLabel: q.label,
            maxMarks: q.maxMarks,
            transcribedAnswer: a['transcribedAnswer'] is String ? a['transcribedAnswer'] as String : '',
            marksAwarded:
                (a['marksAwarded'] is num ? (a['marksAwarded'] as num).toDouble() : 0.0).clamp(0, q.maxMarks).toDouble(),
            confidence: MarkingConfidence.fromValue(a['confidence'] is String ? a['confidence'] as String : 'low'),
          )
        else
          GradedAnswer(
            questionLabel: q.label,
            maxMarks: q.maxMarks,
            transcribedAnswer: '(no answer returned by the AI for this question)',
            marksAwarded: 0,
            confidence: MarkingConfidence.low,
          ),
    ];

    final observationsRaw = responseData['observations'];
    final observations = observationsRaw is List ? observationsRaw.whereType<String>().toList() : <String>[];
    return MarkingGradingResult(answers: answers, observations: observations);
  }
}
