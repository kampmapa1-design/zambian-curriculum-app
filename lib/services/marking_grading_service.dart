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
  }) async {
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
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'pageImagesBase64': pageImagesBase64,
        'questions': [
          for (final q in scheme.questions)
            {
              'label': q.label,
              'expectedAnswerOrKeywords': q.expectedAnswerOrKeywords,
              'maxMarks': q.maxMarks,
            },
        ],
      });

      final answersRaw = (result.data['answers'] as List?) ?? const [];
      final byLabel = {
        for (final a in answersRaw.cast<Map<Object?, Object?>>()) a['questionLabel'] as String: a,
      };

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
              transcribedAnswer: a['transcribedAnswer'] as String? ?? '',
              marksAwarded: ((a['marksAwarded'] as num?) ?? 0).toDouble().clamp(0, q.maxMarks),
              confidence: MarkingConfidence.fromValue(a['confidence'] as String? ?? 'low'),
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
      final observations = ((result.data['observations'] as List?) ?? const []).cast<String>();
      return MarkingGradingResult(answers: answers, observations: observations);
    } on FirebaseFunctionsException catch (e) {
      throw MarkingGradingUnavailable(e.message ?? 'Failed to grade this script.');
    }
  }
}
