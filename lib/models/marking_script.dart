/// Where one captured script sits in the AI-Assisted Marking pipeline (see
/// the 9-stage feature spec). [needsRetry] (Stage 8) and [graded] (Stage
/// 4/5 — AI has produced results, awaiting the Stage 6 mandatory teacher
/// review before anything is final) were added once those stages actually
/// needed them, following the same "don't guess the schema up front"
/// approach as the rest of this model.
enum MarkingScriptStatus {
  captured,
  queued,
  processing,
  graded,
  reviewed,
  needsRetry;

  String get dbValue => name;

  static MarkingScriptStatus fromDb(String value) =>
      MarkingScriptStatus.values.firstWhere((s) => s.dbValue == value, orElse: () => MarkingScriptStatus.captured);

  String get label => switch (this) {
        MarkingScriptStatus.captured => 'Captured',
        MarkingScriptStatus.queued => 'Queued',
        MarkingScriptStatus.processing => 'Processing',
        MarkingScriptStatus.graded => 'Graded — needs review',
        MarkingScriptStatus.reviewed => 'Reviewed',
        MarkingScriptStatus.needsRetry => 'Needs Retry',
      };
}

/// How confident the AI grader was in one answer's transcription/marking
/// (Stage 4 asks for this per answer; Stage 5 is what categorizes and
/// surfaces it). Never computed from the mark alone — this is whatever
/// confidence value the AI provider itself returned for that answer.
enum MarkingConfidence {
  high,
  medium,
  low;

  static MarkingConfidence fromValue(String value) => switch (value.toLowerCase()) {
        'high' => MarkingConfidence.high,
        'medium' => MarkingConfidence.medium,
        _ => MarkingConfidence.low,
      };

  String get label => switch (this) {
        MarkingConfidence.high => 'High confidence',
        MarkingConfidence.medium => 'Medium confidence',
        MarkingConfidence.low => 'Low confidence',
      };
}

/// One question's AI-graded result (Stage 4 output) — [marksAwarded] and
/// [transcribedAnswer] start as whatever the AI returned, but both are
/// mutable at review time (Stage 6): [teacherEdited] tracks whether a
/// human has since changed either, so a final marksheet (Stage 7) can
/// show what the AI said versus what was actually kept.
class GradedAnswer {
  final String questionLabel;
  final double maxMarks;
  final String transcribedAnswer;
  final double marksAwarded;
  final MarkingConfidence confidence;
  final bool teacherEdited;

  const GradedAnswer({
    required this.questionLabel,
    required this.maxMarks,
    required this.transcribedAnswer,
    required this.marksAwarded,
    required this.confidence,
    this.teacherEdited = false,
  });

  GradedAnswer copyWith({String? transcribedAnswer, double? marksAwarded, bool? teacherEdited}) => GradedAnswer(
        questionLabel: questionLabel,
        maxMarks: maxMarks,
        transcribedAnswer: transcribedAnswer ?? this.transcribedAnswer,
        marksAwarded: marksAwarded ?? this.marksAwarded,
        confidence: confidence,
        teacherEdited: teacherEdited ?? this.teacherEdited,
      );

  factory GradedAnswer.fromJson(Map<String, dynamic> json) => GradedAnswer(
        questionLabel: json['questionLabel'] as String,
        maxMarks: (json['maxMarks'] as num).toDouble(),
        transcribedAnswer: json['transcribedAnswer'] as String,
        marksAwarded: (json['marksAwarded'] as num).toDouble(),
        confidence: MarkingConfidence.fromValue(json['confidence'] as String? ?? 'low'),
        teacherEdited: json['teacherEdited'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'questionLabel': questionLabel,
        'maxMarks': maxMarks,
        'transcribedAnswer': transcribedAnswer,
        'marksAwarded': marksAwarded,
        'confidence': confidence.name,
        'teacherEdited': teacherEdited,
      };
}

/// One student's answer script — a set of page images captured in one
/// burst-capture session (Stage 1), later graded as a unit (Stage 4
/// onward). Stored fully offline; see [MarkingScriptRepository].
class MarkingScript {
  final String id;
  final String studentName;
  final String? studentIdNumber;
  final int scriptNumber;

  /// File names only (relative to this script's own subdirectory), in
  /// page order — not full paths, since the app documents directory
  /// itself can move between app versions/reinstalls.
  final List<String> pageFileNames;

  final DateTime capturedAt;
  final MarkingScriptStatus status;

  /// The marking scheme this script is linked to — set when the script is
  /// queued (Stage 2), required before Stage 4 grading can run.
  final String? schemeId;

  /// Stage 4's output, one entry per question in the linked scheme — null
  /// until grading actually completes.
  final List<GradedAnswer>? gradedAnswers;

  /// Set when [status] is [MarkingScriptStatus.needsRetry] (Stage 8) —
  /// shown to the teacher so a retry isn't a mystery.
  final String? lastError;

  const MarkingScript({
    required this.id,
    required this.studentName,
    this.studentIdNumber,
    required this.scriptNumber,
    required this.pageFileNames,
    required this.capturedAt,
    this.status = MarkingScriptStatus.captured,
    this.schemeId,
    this.gradedAnswers,
    this.lastError,
  });

  int get pageCount => pageFileNames.length;

  double? get totalAwarded {
    final answers = gradedAnswers;
    if (answers == null) return null;
    return answers.fold<double>(0.0, (sum, a) => sum + a.marksAwarded);
  }

  double? get totalPossible {
    final answers = gradedAnswers;
    if (answers == null) return null;
    return answers.fold<double>(0.0, (sum, a) => sum + a.maxMarks);
  }

  MarkingScript copyWith({
    List<String>? pageFileNames,
    MarkingScriptStatus? status,
    String? schemeId,
    List<GradedAnswer>? gradedAnswers,
    String? lastError,
    bool clearLastError = false,
  }) =>
      MarkingScript(
        id: id,
        studentName: studentName,
        studentIdNumber: studentIdNumber,
        scriptNumber: scriptNumber,
        pageFileNames: pageFileNames ?? this.pageFileNames,
        capturedAt: capturedAt,
        status: status ?? this.status,
        schemeId: schemeId ?? this.schemeId,
        gradedAnswers: gradedAnswers ?? this.gradedAnswers,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
      );

  factory MarkingScript.fromJson(Map<String, dynamic> json) => MarkingScript(
        id: json['id'] as String,
        studentName: json['studentName'] as String,
        studentIdNumber: json['studentIdNumber'] as String?,
        scriptNumber: json['scriptNumber'] as int,
        pageFileNames: (json['pageFileNames'] as List).cast<String>(),
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        status: MarkingScriptStatus.fromDb(json['status'] as String? ?? 'captured'),
        schemeId: json['schemeId'] as String?,
        gradedAnswers: (json['gradedAnswers'] as List?)
            ?.cast<Map<String, dynamic>>()
            .map(GradedAnswer.fromJson)
            .toList(),
        lastError: json['lastError'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'studentName': studentName,
        'studentIdNumber': studentIdNumber,
        'scriptNumber': scriptNumber,
        'pageFileNames': pageFileNames,
        'capturedAt': capturedAt.toIso8601String(),
        'status': status.dbValue,
        'schemeId': schemeId,
        'gradedAnswers': gradedAnswers?.map((a) => a.toJson()).toList(),
        'lastError': lastError,
      };
}

class MarkingScriptCatalog {
  final List<MarkingScript> scripts;

  const MarkingScriptCatalog({required this.scripts});

  factory MarkingScriptCatalog.empty() => const MarkingScriptCatalog(scripts: []);

  factory MarkingScriptCatalog.fromJson(Map<String, dynamic> json) => MarkingScriptCatalog(
        scripts: (json['scripts'] as List).cast<Map<String, dynamic>>().map(MarkingScript.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'scripts': [for (final s in scripts) s.toJson()]};

  /// The next free script number — one past the highest already used,
  /// so numbering a new batch continues where the last one left off.
  int get nextScriptNumber => scripts.isEmpty ? 1 : scripts.map((s) => s.scriptNumber).reduce((a, b) => a > b ? a : b) + 1;
}
