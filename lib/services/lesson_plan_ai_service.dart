import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/lesson_plan.dart';
import 'auth_service.dart';
import 'metered_call.dart';
import 'senior_secondary_content_filter.dart';

/// One AI-generated progression row, keyed to a real lesson stage name —
/// mirrors [LessonProgressionRow] but without `durationMinutes`, which the
/// AI is never asked for (teachers set real period length themselves).
class LessonPlanAiProgressionRow {
  final String stage;

  /// Only ever returned when the request asked for a content column (see
  /// [LessonPlanAiService.generate]'s `contentColumnMode`) — empty otherwise,
  /// including from a server that predates the field.
  final String content;
  final String teacherRole;
  final String learnersRole;
  final String assessmentCriteria;

  const LessonPlanAiProgressionRow({
    required this.stage,
    this.content = '',
    required this.teacherRole,
    required this.learnersRole,
    required this.assessmentCriteria,
  });

  factory LessonPlanAiProgressionRow.fromMap(Map<Object?, Object?> map) => LessonPlanAiProgressionRow(
        stage: map['stage'] as String? ?? '',
        content: map['content'] as String? ?? '',
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

  /// The same result with every text field cleaned for a Grade 10-12 (OBC)
  /// document — Form 1-5 mentions and placeholder question marks removed
  /// (see senior_secondary_content_filter.dart). A defensive second layer:
  /// the server is also told not to produce them.
  LessonPlanAiResult cleanedForSeniorSecondary() => LessonPlanAiResult(
        rationale: cleanGeneratedText(rationale),
        priorKnowledge: cleanGeneratedText(priorKnowledge),
        tlm: cleanGeneratedText(tlm),
        expectedStandard: cleanGeneratedText(expectedStandard),
        progression: [
          for (final r in progression)
            LessonPlanAiProgressionRow(
              stage: r.stage,
              content: cleanGeneratedText(r.content),
              teacherRole: cleanGeneratedText(r.teacherRole),
              learnersRole: cleanGeneratedText(r.learnersRole),
              assessmentCriteria: cleanGeneratedText(r.assessmentCriteria),
            ),
        ],
      );

  /// Merges this result's stage rows onto [existing] by matching stage
  /// name (case/whitespace-insensitive) — any stage the AI didn't return
  /// (or a custom-template stage it wasn't asked about) keeps its current
  /// content rather than being blanked. Duration is never touched here —
  /// that stays whatever the teacher already set (or blank).
  ///
  /// [includeContent] is true only for a template with its own content
  /// column; even then an empty AI `content` keeps the row's existing
  /// (offline-generated) content rather than blanking it.
  List<LessonProgressionRow> mergedProgression(List<LessonProgressionRow> existing, {bool includeContent = false}) {
    String norm(String s) => s.toLowerCase().trim();
    final byStage = {for (final row in progression) norm(row.stage): row};
    return [
      for (final row in existing)
        if (byStage[norm(row.stage)] case final ai?)
          row.copyWith(
            content: includeContent && ai.content.trim().isNotEmpty ? ai.content : null,
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
  LessonPlanAiService({FirebaseFunctions? functions}) : _providedFunctions = functions;

  // Lazy: resolving FirebaseFunctions.instance needs Firebase.initializeApp() to have
  // succeeded; constructing this service must never throw just because it hasn't.
  final FirebaseFunctions? _providedFunctions;
  FirebaseFunctions get _functions => _providedFunctions ?? FirebaseFunctions.instance;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// [subject] is required — real, reported bug fixed 2026-09-03: without
  /// it, a generic topic name gave the model nothing to disambiguate
  /// against its own general knowledge, and it could plan a lesson around
  /// a different subject's version of a similarly-named topic. See
  /// `buildLessonPlanPrompt` in index.ts for the actual grounding
  /// instruction this enables.
  Future<LessonPlanAiResult> generate({
    required String topic,
    String? subtopic,
    required String subject,
    String? grade,
    required List<String> competencies,
    required List<String> objectives,
    String? references,
    required List<String> progressionStages,
    String? subjectContentExcerpt,
    // "Priority Content Area" (2026-09-12, per explicit request): a short
    // teacher-typed phrase naming specific content buried inside this
    // topic (e.g. "rise and fall of Shaka Zulu" within "The Mfecane") that
    // should make up roughly half of this lesson's real content.
    // [priorityContext] is whatever this app already found on-device about
    // it (see PriorityContentResolver) — null tells the server nothing
    // local was found, so it does one real online search instead.
    String? priorityPhrase,
    String? priorityContext,
    // OBC template work (2026-09-26): 'column' asks for a per-stage
    // `content` (learning points) alongside the roles; 'omitted' tells the
    // model the template has no such column and to leave subject content
    // out of the role columns. Null (every other template) sends nothing —
    // the request and response are exactly as before.
    String? contentColumnMode,
    // Grade 10-12 (OBC): tells the model never to mention Form 1-5 or its
    // content (use it silently) and never to leave question marks as
    // placeholders (2026-09-27). The result is also cleaned client-side.
    bool seniorSecondary = false,
  }) async {
    if (!await isOnline) {
      throw const LessonPlanAiUnavailable(
        "You're offline. Connect to the internet to generate an AI-enhanced lesson plan.",
      );
    }

    await AuthService.instance.ensureSignedIn();

    final callable = meteredCallable(_functions, 'generateLessonPlan');
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'topic': topic,
        if (subtopic != null) 'subtopic': subtopic,
        'subject': subject,
        if (grade != null) 'grade': grade,
        'competencies': competencies,
        'objectives': objectives,
        if (references != null) 'references': references,
        'progressionStages': progressionStages,
        if (subjectContentExcerpt != null && subjectContentExcerpt.trim().isNotEmpty)
          'subjectContentExcerpt': subjectContentExcerpt,
        if (priorityPhrase != null && priorityPhrase.trim().isNotEmpty) 'priorityPhrase': priorityPhrase.trim(),
        if (priorityContext != null && priorityContext.trim().isNotEmpty) 'priorityContext': priorityContext,
        if (contentColumnMode != null) 'contentColumnMode': contentColumnMode,
        if (seniorSecondary) 'seniorSecondary': true,
      });
      final parsed = LessonPlanAiResult.fromMap(result.data);
      return seniorSecondary ? parsed.cleanedForSeniorSecondary() : parsed;
    } on FirebaseFunctionsException catch (e) {
      throw LessonPlanAiUnavailable(e.message ?? 'Failed to generate a lesson plan.');
    }
  }
}
