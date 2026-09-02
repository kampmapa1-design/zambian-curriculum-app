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
  /// MarkingSchemePaperStructureScreen (section-by-section marks-per-
  /// question times how many questions are really in each section) —
  /// takes priority over the raw `questions` sum in [totalMarks] whenever
  /// it's set, since it accounts for a paper's real "answer N of M"
  /// structure in a way a flat sum over every listed question cannot.
  /// Null for a scheme that never went through that confirmation step.
  final double? confirmedPaperTotalMarks;

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
  });

  /// The paper's total marks — [confirmedPaperTotalMarks] when a teacher
  /// has confirmed it (see MarkingSchemePaperStructureScreen), otherwise a
  /// plain sum of every listed question's `maxMarks` (the only option
  /// before that confirmation step existed, and still a reasonable
  /// fallback for a paper with no "answer N of M" structure at all).
  double get totalMarks => confirmedPaperTotalMarks ?? questions.fold(0, (sum, q) => sum + q.maxMarks);

  /// Every distinct section name across [questions], in first-appearance
  /// order, skipping questions with no section at all. Empty when the
  /// paper has no section structure.
  List<String> get sectionNames {
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
