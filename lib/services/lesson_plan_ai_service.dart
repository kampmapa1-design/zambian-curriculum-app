import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/lesson_plan.dart';
import 'auth_service.dart';

/// One AI-generated progression row, keyed to a real lesson stage name —
/// mirrors [LessonProgressionRow] but without `durationMinutes`, which the
/// AI is never asked for (teachers set real period length themselves).
class LessonPlanAiProgressionRow {
  final String stage;
  final String teacherRole;
  final String learnersRole;
  final String assessmentCriteria;

  const LessonPlanAiProgressionRow({
    required this.stage,
    required this.teacherRole,
    required this.learnersRole,
    required this.assessmentCriteria,
  });

  factory LessonPlanAiProgressionRow.fromMap(Map<Object?, Object?> map) => LessonPlanAiProgressionRow(
        stage: map['stage'] as String? ?? '',
        teacherRole: map['teacherRole'] as String? ?? '',
        learnersRole: map['learnersRole'] as String? ?? '',
        assessmentCriteria: map['assessmentCriteria'] as String? ?? '',
      );
}

class LessonPlanAiResult {
  final String rationale;
  final String priorKnowledge;
  final String tlm;
  final String expectedStandard;
  final List<LessonPlanAiProgressionRow> progression;

  const LessonPlanAiResult({
    required this.rationale,
    required this.priorKnowledge,
    required this.tlm,
    required this.expectedStandard,
    required this.progression,
  });

  factory LessonPlanAiResult.fromMap(Map<Object?, Object?> map) => LessonPlanAiResult(
        rationale: map['rationale'] as String? ?? '',
        priorKnowledge: map['priorKnowledge'] as String? ?? '',
        tlm: map['tlm'] as String? ?? '',
        expectedStandard: map['expectedStandard'] as String? ?? '',
        progression: ((map['progression'] as List?) ?? const [])
            .map((row) => LessonPlanAiProgressionRow.fromMap(row as Map<Object?, Object?>))
            .toList(),
      );

  /// Merges this result's stage rows onto [existing] by matching stage
  /// name (case/whitespace-insensitive) — any stage the AI didn't return
  /// (or a custom-template stage it wasn't asked about) keeps its current
  /// content rather than being blanked. Duration is never touched here —
  /// that stays whatever the teacher already set (or blank).
  List<LessonProgressionRow> mergedProgression(List<LessonProgressionRow> existing) {
    String norm(String s) => s.toLowerCase().trim();
    final byStage = {for (final row in progression) norm(row.stage): row};
    return [
      for (final row in existing)
        if (byStage[norm(row.stage)] case final ai?)
          row.copyWith(
            teacherRole: ai.teacherRole,
            learnersRole: ai.learnersRole,
            assessmentCriteria: ai.assessmentCriteria,
          )
        else
          row,
    ];
  }
}

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request" — either way there's a user-facing message to show.
class LessonPlanAiUnavailable implements Exception {
  final String message;
  const LessonPlanAiUnavailable(this.message);
  @override
  String toString() => message;
}

/// Calls the `generateLessonPlan` Cloud Function — an optional, request-time
/// AI upgrade for "Generate Lesson Plan", which otherwise fills every field
/// entirely offline (see `generateDefaultProgression`). Same
/// online-required/sign-in pattern as [TeachingNotesService].
class LessonPlanAiService {
  LessonPlanAiService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<LessonPlanAiResult> generate({
    required String topic,
    String? subtopic,
    required List<String> competencies,
    required List<String> objectives,
    String? references,
    required List<String> progressionStages,
    String? subjectContentExcerpt,
  }) async {
    if (!await isOnline) {
      throw const LessonPlanAiUnavailable(
        "You're offline. Connect to the internet to generate an AI-enhanced lesson plan.",
      );
    }

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable('generateLessonPlan');
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'topic': topic,
        if (subtopic != null) 'subtopic': subtopic,
        'competencies': competencies,
        'objectives': objectives,
        if (references != null) 'references': references,
        'progressionStages': progressionStages,
        if (subjectContentExcerpt != null && subjectContentExcerpt.trim().isNotEmpty)
          'subjectContentExcerpt': subjectContentExcerpt,
      });
      return LessonPlanAiResult.fromMap(result.data);
    } on FirebaseFunctionsException catch (e) {
      throw LessonPlanAiUnavailable(e.message ?? 'Failed to generate a lesson plan.');
    }
  }
}
