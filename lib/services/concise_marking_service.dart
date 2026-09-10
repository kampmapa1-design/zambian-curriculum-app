import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/marking_rubric.dart';
import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import 'auth_service.dart';

/// Where, on one of a script's own photographed pages, one answer's real
/// handwritten response sits — Gemini's own best-effort location, never a
/// guess (see gradeMarkingScriptConcise's own Cloud Function comment):
/// [pageIndex]/[box] are both null together whenever the model wasn't
/// confident enough to place it. [box] coordinates are normalized 0-1000
/// across that page's own real width/height (Gemini's standard
/// object-detection convention) — [ScriptAnnotationService] is what turns
/// this into an actual pixel position on the real image.
class AnswerAnnotation {
  final String questionLabel;
  final int? pageIndex;
  final int? yMin;
  final int? xMin;
  final int? yMax;
  final int? xMax;

  const AnswerAnnotation({
    required this.questionLabel,
    this.pageIndex,
    this.yMin,
    this.xMin,
    this.yMax,
    this.xMax,
  });

  bool get hasLocation => pageIndex != null && yMin != null && xMin != null && yMax != null && xMax != null;
}

/// [ConciseMarkingService.grade]'s result — the same real
/// answers/observations shape [MarkingGradingService] already produces
/// (so Concise Marking's own marks flow into the exact same
/// MarkingScript.gradedAnswers a normal grading pass would, and every
/// other screen — Review, Analysis, marksheets — keeps working exactly
/// as it already does), plus [annotations] — one per answer, telling
/// [ScriptAnnotationService] where to draw each mark, when the AI could
/// confidently place it.
class ConciseMarkingResult {
  final List<GradedAnswer> answers;
  final List<String> observations;
  final List<AnswerAnnotation> annotations;

  /// Which section each answer belongs to (question label -> section
  /// name, or null). Fed straight into [ConciseScoreCalculator] so the
  /// "answer N of M per section" rules can be applied deterministically.
  final Map<String, String?> sectionByLabel;

  /// The examination's cover-page rules — populated only when this grade
  /// call did NOT carry a knownRubric (i.e. the first script of a
  /// cohort). Null for every following script, and for a paper with no
  /// section structure at all.
  final MarkingRubric? rubric;

  const ConciseMarkingResult({
    required this.answers,
    required this.observations,
    required this.annotations,
    this.sectionByLabel = const {},
    this.rubric,
  });
}

class ConciseMarkingUnavailable implements Exception {
  final String message;
  const ConciseMarkingUnavailable(this.message);
  @override
  String toString() => message;
}

/// "Concise Marking" (Scan Marker, 2026-09-11, per explicit request) —
/// client side of the `gradeMarkingScriptConcise` Cloud Function. A
/// SEPARATE grading call from [MarkingGradingService]'s own
/// `gradeMarkingScript`, not a shared code path, matching that Cloud
/// Function's own "don't disrupt an established function" reasoning:
/// every other AI-Assisted Marking flow keeps behaving exactly as it
/// already does, unaffected by this.
class ConciseMarkingService {
  ConciseMarkingService({FirebaseFunctions? functions}) : _providedFunctions = functions;

  // Lazy (same fix already applied elsewhere in this app this session —
  // see TopicSearchService/CdcResourcesService/PhotoBatchService's own
  // doc comments) so this service stays constructible without Firebase
  // already initialized.
  final FirebaseFunctions? _providedFunctions;
  FirebaseFunctions get _functions => _providedFunctions ?? FirebaseFunctions.instance;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// Grades one script.
  ///
  /// Pure-AI is the default (2026-09-10, per explicit request): pass no
  /// [scheme] and the AI reads the questions, their marks and the marking
  /// guidance off the paper itself. [referenceScheme] — a saved key the
  /// app auto-detected for this subject — is sent as *reference* only, to
  /// blend the school's own onboarded content with the AI's judgment.
  /// [questionPaperFiles] are optional extra images of the question paper
  /// / official marking guide, for when the answer booklet doesn't carry
  /// the questions. Pass [scheme] only when the teacher deliberately wants
  /// strict key-based marking.
  Future<ConciseMarkingResult> grade({
    required List<File> pageFiles,
    MarkingScheme? scheme,
    MarkingScheme? referenceScheme,
    List<File> questionPaperFiles = const [],
    String? subjectName,
    MarkingRubric? knownRubric,
  }) async {
    try {
      return await _doGrade(pageFiles, scheme, referenceScheme, questionPaperFiles, subjectName, knownRubric)
          .timeout(
        const Duration(seconds: 200),
        onTimeout: () => throw const ConciseMarkingUnavailable(
          'Grading this script is taking too long and may be stuck. Check your connection and try again.',
        ),
      );
    } on ConciseMarkingUnavailable {
      rethrow;
    } catch (error) {
      throw ConciseMarkingUnavailable('Could not grade this script: $error');
    }
  }

  List<Map<String, Object>> _questionsPayload(MarkingScheme s) => [
        for (final q in s.questions)
          {
            'label': q.label,
            'expectedAnswerOrKeywords': q.expectedAnswerOrKeywords,
            'maxMarks': q.maxMarks,
          },
      ];

  Future<ConciseMarkingResult> _doGrade(
    List<File> pageFiles,
    MarkingScheme? scheme,
    MarkingScheme? referenceScheme,
    List<File> questionPaperFiles,
    String? subjectName,
    MarkingRubric? knownRubric,
  ) async {
    if (!await isOnline) {
      throw const ConciseMarkingUnavailable("You're offline. Connect to the internet to grade this script.");
    }
    await AuthService.instance.ensureSignedIn();

    final pageImagesBase64 = [
      for (final file in pageFiles) base64Encode(await file.readAsBytes()),
    ];
    final questionPaperImagesBase64 = [
      for (final file in questionPaperFiles) base64Encode(await file.readAsBytes()),
    ];

    final effectiveSubject = subjectName?.trim().isNotEmpty == true
        ? subjectName!.trim()
        : (scheme?.subjectName ?? referenceScheme?.subjectName);
    final markConventions = scheme?.markConventions ?? referenceScheme?.markConventions ?? const <String>[];
    final examStandardWire = scheme?.examStandard.wireValue ?? referenceScheme?.examStandard.wireValue;

    final callable = _functions.httpsCallable(
      'gradeMarkingScriptConcise',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 170)),
    );

    Object? rawData;
    try {
      final result = await callable.call<Object?>({
        'pageImagesBase64': pageImagesBase64,
        if (scheme != null) 'questions': _questionsPayload(scheme),
        if (scheme == null && referenceScheme != null) 'referenceQuestions': _questionsPayload(referenceScheme),
        if (questionPaperImagesBase64.isNotEmpty) 'questionPaperImagesBase64': questionPaperImagesBase64,
        if (effectiveSubject != null && effectiveSubject.isNotEmpty) 'subjectName': effectiveSubject,
        if (markConventions.isNotEmpty) 'markConventions': markConventions,
        if (examStandardWire != null) 'examStandard': examStandardWire,
        if (knownRubric != null && !knownRubric.isEmpty) 'knownRubric': knownRubric.toJson(),
      });
      rawData = result.data;
    } on FirebaseFunctionsException catch (e) {
      throw ConciseMarkingUnavailable(e.message ?? 'Failed to grade this script.');
    }

    if (rawData is! Map) {
      throw const ConciseMarkingUnavailable('The grading response was in an unexpected format.');
    }
    final responseData = rawData;
    final answersRaw = responseData['answers'];
    if (answersRaw is! List) {
      throw const ConciseMarkingUnavailable('The grading response was in an unexpected format.');
    }

    final byLabel = <String, Map>{};
    final aiOrder = <String>[];
    for (final a in answersRaw) {
      if (a is! Map) continue;
      final label = a['questionLabel'];
      if (label is String && label.trim().isNotEmpty && !byLabel.containsKey(label)) {
        byLabel[label] = a;
        aiOrder.add(label);
      }
    }

    // The question set to build results over. Keyed mode: the scheme's own
    // questions (authoritative marks). Pure-AI: whatever questions the AI
    // itself identified on the paper, with the marks it read off it.
    final questionSet = <({String label, double maxMarks, String? section})>[];
    if (scheme != null) {
      for (final q in scheme.questions) {
        questionSet.add((label: q.label, maxMarks: q.maxMarks, section: q.sectionName));
      }
    } else {
      for (final label in aiOrder) {
        final a = byLabel[label]!;
        final m = a['maxMarks'];
        questionSet.add((
          label: label,
          maxMarks: (m is num && m > 0) ? m.toDouble() : 1.0,
          section: null,
        ));
      }
    }
    if (questionSet.isEmpty) {
      throw const ConciseMarkingUnavailable(
        'The AI could not identify any questions to mark on this script. Try adding a photo of the '
        'question paper, or check the pages are clear and right-way-up.',
      );
    }

    final answers = <GradedAnswer>[];
    final annotations = <AnswerAnnotation>[];
    final sectionByLabel = <String, String?>{};
    for (final q in questionSet) {
      final a = byLabel[q.label];
      final aiSection = a?['sectionName'];
      sectionByLabel[q.label] =
          (aiSection is String && aiSection.trim().isNotEmpty) ? aiSection.trim() : q.section;
      if (a == null) {
        answers.add(GradedAnswer(
          questionLabel: q.label,
          maxMarks: q.maxMarks,
          transcribedAnswer: '(no answer returned by the AI for this question)',
          marksAwarded: 0,
          confidence: MarkingConfidence.low,
        ));
        annotations.add(AnswerAnnotation(questionLabel: q.label));
        continue;
      }
      answers.add(GradedAnswer(
        questionLabel: q.label,
        maxMarks: q.maxMarks,
        transcribedAnswer: a['transcribedAnswer'] is String ? a['transcribedAnswer'] as String : '',
        marksAwarded:
            (a['marksAwarded'] is num ? (a['marksAwarded'] as num).toDouble() : 0.0).clamp(0, q.maxMarks).toDouble(),
        confidence: MarkingConfidence.fromValue(a['confidence'] is String ? a['confidence'] as String : 'low'),
        markingBasis: MarkingBasis.fromValue(a['markingBasis'] is String ? a['markingBasis'] as String : null),
      ));

      final pageIndex = a['pageIndex'];
      final box = a['box'];
      if (pageIndex is num && box is Map) {
        final yMin = box['yMin'], xMin = box['xMin'], yMax = box['yMax'], xMax = box['xMax'];
        if (yMin is num && xMin is num && yMax is num && xMax is num) {
          annotations.add(AnswerAnnotation(
            questionLabel: q.label,
            pageIndex: pageIndex.toInt(),
            yMin: yMin.toInt(),
            xMin: xMin.toInt(),
            yMax: yMax.toInt(),
            xMax: xMax.toInt(),
          ));
          continue;
        }
      }
      annotations.add(AnswerAnnotation(questionLabel: q.label));
    }

    final observationsRaw = responseData['observations'];
    final observations = observationsRaw is List ? observationsRaw.whereType<String>().toList() : <String>[];

    MarkingRubric? rubric;
    final rubricRaw = responseData['rubric'];
    if (rubricRaw is Map) {
      final parsed = MarkingRubric.fromJson(rubricRaw.cast<String, dynamic>());
      if (!parsed.isEmpty) rubric = parsed;
    }

    return ConciseMarkingResult(
      answers: answers,
      observations: observations,
      annotations: annotations,
      sectionByLabel: sectionByLabel,
      rubric: rubric,
    );
  }
}
