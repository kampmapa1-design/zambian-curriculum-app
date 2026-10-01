import 'marking_scheme_node.dart';

/// Which real marking regime a [MarkingScheme] follows — Rules Engine
/// (2026-09-08, per explicit request, see the user's own
/// Smart_Teacher_AI_Marking_Rules_Engine-1.md design doc). Set from
/// [DerivedMarkingKey.examStandardHint] as a starting suggestion (see
/// MarkingSchemePaperStructureScreen), always teacher-confirmable, same
/// "never auto-apply an AI/heuristic judgment call" standing rule as
/// [SectionMarkingStyle].
enum MarkingExamStandard {
  /// A standardized mock/national/final exam — marked to the identical
  /// strictness as the real ECZ national exam, no softening either way.
  nationalMock,

  /// An ordinary school-based Continuous Assessment test (a Mid-Term Test
  /// or End-of-Term Test) — marked accurately per the scheme's own
  /// conventions, same rigor as any other script (see gradeMarkingScript's
  /// own `examStandardGuidance`, Cloud Function side).
  schoolCa,

  /// Genuinely unclear, or never confirmed — the default for every scheme
  /// saved before this field existed. Grading proceeds with no special
  /// standard-specific guidance either way, same as before this field
  /// existed.
  unspecified;

  String get dbValue => name;

  static MarkingExamStandard fromValue(String? value) => switch (value) {
        'nationalMock' => MarkingExamStandard.nationalMock,
        'schoolCa' => MarkingExamStandard.schoolCa,
        _ => MarkingExamStandard.unspecified,
      };

  /// The Cloud Function's own wire value for `examStandard` — null for
  /// [unspecified] (the absence of a strong signal, not a third real
  /// value the AI needs to reason about).
  String? get wireValue => switch (this) {
        MarkingExamStandard.nationalMock => 'NATIONAL_MOCK',
        MarkingExamStandard.schoolCa => 'SCHOOL_CA',
        MarkingExamStandard.unspecified => null,
      };

  String get label => switch (this) {
        MarkingExamStandard.nationalMock => 'National Mock Standard',
        MarkingExamStandard.schoolCa => 'School CA Test',
        MarkingExamStandard.unspecified => 'Not sure / other',
      };
}

/// One question within a [MarkingScheme] — what a teacher fills in when
/// building the scheme, and what Stage 4 (AI grading dispatch) will later
/// send to the AI provider alongside a script's page images.
class MarkingSchemeQuestion {
  final String label;

  /// The expected answer, or a comma/line-separated list of keywords the
  /// AI grader should look for — free text, since teachers vary in how
  /// precisely they can specify this. Stage 4 sends this as-is; how
  /// strictly it's matched is a grading-prompt concern, not a data-model
  /// one.
  final String expectedAnswerOrKeywords;

  final double maxMarks;

  /// Which section of the paper this question belongs to (e.g. "Section
  /// A"), or null/blank for a paper with no section structure at all.
  /// Populated either by the AI derivation step (deriveMarkingKeyFromQuestionPaper
  /// now detects section headings instead of discarding them — see that
  /// Cloud Function's own comment) or typed by the teacher directly in
  /// MarkingSchemeBuilderScreen. Purely organisational: grading itself
  /// still matches by [label] alone, same as before this field existed.
  final String? sectionName;

  const MarkingSchemeQuestion({
    required this.label,
    required this.expectedAnswerOrKeywords,
    required this.maxMarks,
    this.sectionName,
  });

  MarkingSchemeQuestion copyWith({
    String? label,
    String? expectedAnswerOrKeywords,
    double? maxMarks,
    String? sectionName,
  }) =>
      MarkingSchemeQuestion(
        label: label ?? this.label,
        expectedAnswerOrKeywords: expectedAnswerOrKeywords ?? this.expectedAnswerOrKeywords,
        maxMarks: maxMarks ?? this.maxMarks,
        sectionName: sectionName ?? this.sectionName,
      );

  factory MarkingSchemeQuestion.fromJson(Map<String, dynamic> json) => MarkingSchemeQuestion(
        label: json['label'] as String,
        expectedAnswerOrKeywords: json['expectedAnswerOrKeywords'] as String,
        maxMarks: (json['maxMarks'] as num).toDouble(),
        sectionName: json['sectionName'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'expectedAnswerOrKeywords': expectedAnswerOrKeywords,
        'maxMarks': maxMarks,
        if (sectionName != null) 'sectionName': sectionName,
      };
}

/// A reusable marking scheme for one assessment — built once, linked to
/// the relevant subject/topic from the app's real syllabus data (see
/// SubjectGradeTopicPickerScreen/TermTopicPickerScreen, which is how a
/// teacher picks [subjectName]/[topicName]/[subTopicName]), then applied
/// across every script from that same assessment (Stage 4 onward).
class MarkingScheme {
  final String id;
  final String title;
  final String subjectName;
  final String gradeName;
  final String topicName;
  final String? subTopicName;
  final List<MarkingSchemeQuestion> questions;
  final DateTime createdAt;

  /// When true, MarksheetDocumentService keeps scripts in scriptNumber
  /// order (capture/import order) instead of its normal alphabetical-by-
  /// surname default. False (alphabetical) for every scheme created
  /// through the app's current flows; kept as a real, respected field
  /// rather than removed in case a future capture path wants to offer
  /// the choice again.
  final bool preserveScriptOrder;

  /// How many questions a candidate is actually required to answer on
  /// this paper, as the teacher confirmed on MarkingSchemePaperStructureScreen
  /// — null for a scheme that never went through that confirmation (every
  /// scheme saved before this field existed, or one where the teacher
  /// skipped it). Distinct from `questions.length`: a paper can legitimately
  /// list more questions than a candidate must answer (e.g. "Section B:
  /// answer any 3 of the following 5 essay questions"), and that gap is
  /// exactly what this field lets the app flag rather than silently sum
  /// every listed question into the total.
  final int? requiredAnswerCount;

  /// The paper's own real total, as the teacher confirmed it on
  /// MarkingSchemePaperStructureScreen (each section's own real total,
  /// per how that section is actually marked — see
  /// [MarkingSchemeSectionMarks]) — takes priority over the raw
  /// `questions` sum in [totalMarks] whenever it's set, since it accounts
  /// for a paper's real "answer N of M"/section-total structure in a way
  /// a flat sum over every listed question cannot. Null for a scheme that
  /// never went through that confirmation step.
  final double? confirmedPaperTotalMarks;

  /// A teacher's own free-text note on how marks should be allocated for
  /// THIS assessment (2026-09-05, per explicit request) — asked on
  /// MarkingSchemePaperStructureScreen specifically for an assessment that
  /// doesn't look like a standardized mock/national exam (an ordinary
  /// class test, whose mark-allocation rules genuinely vary assessment to
  /// assessment, unlike a real exam's well-known Section A/B/C/D
  /// convention). Purely a record of the teacher's own stated intent —
  /// never generated or altered by the app; null when never asked (a
  /// standardized-exam-looking assessment, or a scheme saved before this
  /// field existed).
  final String? gradingGuidance;

  /// Rules Engine (2026-09-08) — see [MarkingExamStandard]'s own doc
  /// comment. Defaults to [MarkingExamStandard.unspecified] for every
  /// scheme saved before this field existed.
  final MarkingExamStandard examStandard;

  /// This assessment's own front-page-stated marking conventions (e.g.
  /// "one mark per bullet point", "accept alternative answers separated
  /// by /") — Rules Engine (2026-09-08), from [DerivedMarkingKey
  /// .markConventions] as a starting draft, always teacher-editable on
  /// MarkingSchemePaperStructureScreen. Sent to gradeMarkingScript
  /// verbatim, taking priority over that Cloud Function's own universal
  /// defaults. Empty for manual entry, a scheme whose source document
  /// stated no explicit conventions, or a scheme saved before this field
  /// existed.
  final List<String> markConventions;

  /// The paper's real Section → Question → Part → Sub-part structure
  /// (Marking Scheme Structure, Stage 1, 2026-09-22) — empty for every
  /// scheme built before this field existed, or one whose source paper
  /// genuinely has no section structure at all. When non-empty, this is
  /// the source of truth for grading dispatch and section-aware scoring
  /// (see [effectiveQuestions] and ConciseScoreCalculator's tree-aware
  /// path) — [questions] is then a DERIVED flat view kept in sync at
  /// construction time, not independently authored.
  final List<MarkingSchemeSection> sections;

  const MarkingScheme({
    required this.id,
    required this.title,
    required this.subjectName,
    required this.gradeName,
    required this.topicName,
    this.subTopicName,
    required this.questions,
    required this.createdAt,
    this.preserveScriptOrder = false,
    this.requiredAnswerCount,
    this.confirmedPaperTotalMarks,
    this.gradingGuidance,
    this.examStandard = MarkingExamStandard.unspecified,
    this.markConventions = const [],
    this.sections = const [],
  });

  bool get hasSectionTree => sections.isNotEmpty;

  /// The flat, per-question view every existing grading-dispatch/review
  /// consumer already expects — [questions] itself for a scheme with no
  /// tree (unchanged, pre-Stage-1 behaviour), or every section's own
  /// [MarkingSchemeSection.flattenedQuestions] in section order when a
  /// tree is present. Always prefer this over reading [questions] directly
  /// once a scheme might have a tree, so a Stage-1 scheme's real
  /// Part/Sub-part structure is never silently ignored.
  List<MarkingSchemeQuestion> get effectiveQuestions =>
      hasSectionTree ? [for (final s in sections) ...s.flattenedQuestions()] : questions;

  /// The paper's total marks — [confirmedPaperTotalMarks] when a teacher
  /// has confirmed it (see MarkingSchemePaperStructureScreen), otherwise a
  /// plain sum of every listed question's `maxMarks` (the only option
  /// before that confirmation step existed, and still a reasonable
  /// fallback for a paper with no "answer N of M" structure at all).
  double get totalMarks =>
      confirmedPaperTotalMarks ??
      (hasSectionTree
          ? sections.fold(0.0, (sum, s) => sum + s.totalMarksIfAllAnswered)
          : questions.fold(0, (sum, q) => sum + q.maxMarks));

  /// Every distinct section name, in first-appearance order — read
  /// straight from [sections] when a tree exists (which also correctly
  /// includes a section with zero questions confirmed so far), otherwise
  /// derived from [questions] as before Stage 1. Empty when the paper has
  /// no section structure.
  List<String> get sectionNames {
    if (hasSectionTree) return [for (final s in sections) s.name];
    final seen = <String>{};
    final ordered = <String>[];
    for (final q in questions) {
      final name = q.sectionName?.trim();
      if (name == null || name.isEmpty || seen.contains(name)) continue;
      seen.add(name);
      ordered.add(name);
    }
    return ordered;
  }

  MarkingScheme copyWith({
    String? title,
    List<MarkingSchemeQuestion>? questions,
    bool? preserveScriptOrder,
    int? requiredAnswerCount,
    double? confirmedPaperTotalMarks,
    String? gradingGuidance,
    MarkingExamStandard? examStandard,
    List<String>? markConventions,
    List<MarkingSchemeSection>? sections,
  }) =>
      MarkingScheme(
        id: id,
        title: title ?? this.title,
        subjectName: subjectName,
        gradeName: gradeName,
        topicName: topicName,
        subTopicName: subTopicName,
        questions: questions ?? this.questions,
        createdAt: createdAt,
        preserveScriptOrder: preserveScriptOrder ?? this.preserveScriptOrder,
        requiredAnswerCount: requiredAnswerCount ?? this.requiredAnswerCount,
        confirmedPaperTotalMarks: confirmedPaperTotalMarks ?? this.confirmedPaperTotalMarks,
        gradingGuidance: gradingGuidance ?? this.gradingGuidance,
        examStandard: examStandard ?? this.examStandard,
        markConventions: markConventions ?? this.markConventions,
        sections: sections ?? this.sections,
      );

  factory MarkingScheme.fromJson(Map<String, dynamic> json) => MarkingScheme(
        id: json['id'] as String,
        title: json['title'] as String,
        subjectName: json['subjectName'] as String,
        gradeName: json['gradeName'] as String,
        topicName: json['topicName'] as String,
        subTopicName: json['subTopicName'] as String?,
        questions: (json['questions'] as List)
            .cast<Map<String, dynamic>>()
            .map(MarkingSchemeQuestion.fromJson)
            .toList(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        preserveScriptOrder: json['preserveScriptOrder'] as bool? ?? false,
        requiredAnswerCount: json['requiredAnswerCount'] as int?,
        confirmedPaperTotalMarks: (json['confirmedPaperTotalMarks'] as num?)?.toDouble(),
        gradingGuidance: json['gradingGuidance'] as String?,
        examStandard: MarkingExamStandard.fromValue(json['examStandard'] as String?),
        markConventions: (json['markConventions'] as List?)?.cast<String>() ?? const [],
        sections: (json['sections'] as List?)
                ?.whereType<Map>()
                .map((m) => MarkingSchemeSection.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subjectName': subjectName,
        'gradeName': gradeName,
        'topicName': topicName,
        'subTopicName': subTopicName,
        'questions': [for (final q in questions) q.toJson()],
        'createdAt': createdAt.toIso8601String(),
        'preserveScriptOrder': preserveScriptOrder,
        if (requiredAnswerCount != null) 'requiredAnswerCount': requiredAnswerCount,
        if (confirmedPaperTotalMarks != null) 'confirmedPaperTotalMarks': confirmedPaperTotalMarks,
        if (gradingGuidance != null) 'gradingGuidance': gradingGuidance,
        'examStandard': examStandard.dbValue,
        if (markConventions.isNotEmpty) 'markConventions': markConventions,
        if (sections.isNotEmpty) 'sections': [for (final s in sections) s.toJson()],
      };
}

class MarkingSchemeCatalog {
  final List<MarkingScheme> schemes;

  const MarkingSchemeCatalog({required this.schemes});

  factory MarkingSchemeCatalog.empty() => const MarkingSchemeCatalog(schemes: []);

  factory MarkingSchemeCatalog.fromJson(Map<String, dynamic> json) => MarkingSchemeCatalog(
        schemes: (json['schemes'] as List).cast<Map<String, dynamic>>().map(MarkingScheme.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'schemes': [for (final s in schemes) s.toJson()]};
}
