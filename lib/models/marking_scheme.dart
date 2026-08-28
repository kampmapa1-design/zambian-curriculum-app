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

  const MarkingSchemeQuestion({
    required this.label,
    required this.expectedAnswerOrKeywords,
    required this.maxMarks,
  });

  MarkingSchemeQuestion copyWith({
    String? label,
    String? expectedAnswerOrKeywords,
    double? maxMarks,
  }) =>
      MarkingSchemeQuestion(
        label: label ?? this.label,
        expectedAnswerOrKeywords: expectedAnswerOrKeywords ?? this.expectedAnswerOrKeywords,
        maxMarks: maxMarks ?? this.maxMarks,
      );

  factory MarkingSchemeQuestion.fromJson(Map<String, dynamic> json) => MarkingSchemeQuestion(
        label: json['label'] as String,
        expectedAnswerOrKeywords: json['expectedAnswerOrKeywords'] as String,
        maxMarks: (json['maxMarks'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'expectedAnswerOrKeywords': expectedAnswerOrKeywords,
        'maxMarks': maxMarks,
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
  /// surname default — set from an explicit "Arrange in alphabetical
  /// order?" / No answer at class-list-import time (see
  /// ClassListImportScreen); false (alphabetical) for every other scheme.
  final bool preserveScriptOrder;

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
  });

  double get totalMarks => questions.fold(0, (sum, q) => sum + q.maxMarks);

  MarkingScheme copyWith({String? title, List<MarkingSchemeQuestion>? questions, bool? preserveScriptOrder}) =>
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
