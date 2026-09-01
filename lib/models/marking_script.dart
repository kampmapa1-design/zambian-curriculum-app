/// A candidate's gender, as recorded on the script — required for the
/// Analysis screen's gender-segmented grade breakdown (male/female counts
/// per grade band). Deliberately just these two: that's the whole of what
/// the Analysis feature groups by; there's no third "not stated" bucket
/// because every script must have one set at capture time.
enum CandidateGender {
  male,
  female;

  String get dbValue => name;

  /// Required at capture time (see BurstCaptureScreen) for every script
  /// this app saves from here on — this fallback exists for scripts saved
  /// before this field existed (no real value to recover) and for
  /// genuinely corrupted/hand-edited JSON, matching this file's existing
  /// pattern of defaulting rather than throwing on a bad record
  /// (MarkingScriptStatus.fromDb does the same). A pre-existing script
  /// that lands on this default is visibly editable, same as any other
  /// field, the next time it's opened — it isn't hidden as if it were
  /// verified data.
  static CandidateGender fromDb(String value) =>
      CandidateGender.values.firstWhere((g) => g.dbValue == value, orElse: () => CandidateGender.male);

  String get label => switch (this) {
        CandidateGender.male => 'Male',
        CandidateGender.female => 'Female',
      };
}

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

/// One question-number-tagged answer segment, carried over from Test
/// Submission's Stage 3 transcription when a script is created via that
/// feature's "Send to Marking" bridge (Stage 10, added 2026-09-02) —
/// null for every ordinary captured script. Passed to `gradeMarkingScript`
/// as a hint (never ground truth — see that function's prompt) so
/// grading doesn't have to re-detect question boundaries from scratch.
class PreSegmentedAnswer {
  final String questionNumber;
  final String text;

  const PreSegmentedAnswer({required this.questionNumber, required this.text});

  Map<String, dynamic> toJson() => {'questionNumber': questionNumber, 'text': text};

  factory PreSegmentedAnswer.fromJson(Map<String, dynamic> json) => PreSegmentedAnswer(
        questionNumber: json['questionNumber'] as String? ?? 'Unlabeled',
        text: json['text'] as String? ?? '',
      );
}

/// One student's answer script — a set of page images captured in one
/// burst-capture session (Stage 1), later graded as a unit (Stage 4
/// onward). Stored fully offline; see [MarkingScriptRepository].
class MarkingScript {
  final String id;

  /// Kept as separate fields (not one combined name) deliberately — display
  /// order is first name above surname, but results lists sort by surname
  /// (the standard convention), and a future auto-detected name needs each
  /// part independently editable.
  final String firstName;
  final String surname;

  final CandidateGender gender;

  /// True when a teacher actually set [gender] (the details form always
  /// requires it). False means it's a last-resort placeholder — see
  /// ScriptBatchCaptureScreen, which doesn't stop to ask per script
  /// during continuous capture — and the queue/review UI should visibly
  /// flag it as needing a teacher's confirmation before it's trusted in
  /// Analysis counts.
  final bool genderConfirmed;

  final String? studentIdNumber;
  final int scriptNumber;

  /// Captured once per script, up front — not inferred later from whatever
  /// marking scheme the script eventually gets queued against, so it's
  /// visible immediately and survives even if the script is never queued.
  final String subjectName;
  final String gradeName;

  /// The candidate's actual class/stream (e.g. "10A", "Form 2 Blue") — a
  /// teacher-entered free-text field, distinct from [gradeName] (the
  /// syllabus level picked once for the whole capture flow). Added
  /// 2026-08-30 alongside manual name/ID entry replacing AI candidate-name
  /// detection (cost reduction — see CandidateNameDetectionService's doc
  /// comment). Optional since scripts saved before this field existed have
  /// no value for it; empty string, not null, for newly-saved scripts with
  /// nothing entered.
  final String classLevel;

  /// File names only (relative to this script's own subdirectory), in
  /// page order — not full paths, since the app documents directory
  /// itself can move between app versions/reinstalls. Still populated
  /// (and [pageCount] still reports the real original count) even after
  /// [photosDiscarded] — see that field's doc for why the list itself is
  /// deliberately not cleared.
  final List<String> pageFileNames;

  /// Stage H — once true, the files [pageFileNames] names no longer exist
  /// on disk (deliberately deleted to free storage; see
  /// MarkingScriptRepository.discardPhotos), while every mark/answer/
  /// observation on this script is kept exactly as before. The names
  /// themselves stay in [pageFileNames] purely so [pageCount] keeps
  /// reporting how many pages this script originally had — no code should
  /// ever attempt to actually open a file from [pageFileNames] once this
  /// is true.
  final bool photosDiscarded;

  final DateTime capturedAt;
  final MarkingScriptStatus status;

  /// The marking scheme this script is linked to — set when the script is
  /// queued (Stage 2), required before Stage 4 grading can run.
  final String? schemeId;

  /// Stage 4's output, one entry per question in the linked scheme — null
  /// until grading actually completes.
  final List<GradedAnswer>? gradedAnswers;

  /// 3-5 AI-generated observations about this candidate's performance,
  /// grounded in the marking scheme — set alongside [gradedAnswers], null
  /// until grading completes for the same reason.
  final List<String>? observations;

  /// Set when [status] is [MarkingScriptStatus.needsRetry] (Stage 8) —
  /// shown to the teacher so a retry isn't a mystery.
  final String? lastError;

  /// See [PreSegmentedAnswer]'s doc — set once, at creation, by the Test
  /// Submission bridge; never edited afterward (not in [copyWith]).
  final List<PreSegmentedAnswer>? preSegmentedAnswers;

  const MarkingScript({
    required this.id,
    required this.firstName,
    required this.surname,
    required this.gender,
    this.genderConfirmed = true,
    this.studentIdNumber,
    required this.scriptNumber,
    required this.subjectName,
    required this.gradeName,
    this.classLevel = '',
    required this.pageFileNames,
    this.photosDiscarded = false,
    required this.capturedAt,
    this.status = MarkingScriptStatus.captured,
    this.schemeId,
    this.gradedAnswers,
    this.observations,
    this.lastError,
    this.preSegmentedAnswers,
  });

  int get pageCount => pageFileNames.length;

  /// One-line form for contexts that can't show the two-line
  /// first-name-above-surname layout (AppBar titles, CSV single-cell
  /// contexts that want a combined name, etc).
  String get fullName => '$firstName $surname'.trim();

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
    String? firstName,
    String? surname,
    CandidateGender? gender,
    bool? genderConfirmed,
    String? classLevel,
    List<String>? pageFileNames,
    bool? photosDiscarded,
    MarkingScriptStatus? status,
    String? schemeId,
    List<GradedAnswer>? gradedAnswers,
    List<String>? observations,
    String? lastError,
    bool clearLastError = false,
  }) =>
      MarkingScript(
        id: id,
        firstName: firstName ?? this.firstName,
        surname: surname ?? this.surname,
        gender: gender ?? this.gender,
        // Setting gender explicitly implies it's now confirmed, unless the
        // caller says otherwise — covers both "teacher corrected it" (should
        // become confirmed) and internal copies that pass neither.
        genderConfirmed: genderConfirmed ?? (gender != null ? true : this.genderConfirmed),
        studentIdNumber: studentIdNumber,
        scriptNumber: scriptNumber,
        subjectName: subjectName,
        gradeName: gradeName,
        classLevel: classLevel ?? this.classLevel,
        pageFileNames: pageFileNames ?? this.pageFileNames,
        photosDiscarded: photosDiscarded ?? this.photosDiscarded,
        capturedAt: capturedAt,
        status: status ?? this.status,
        schemeId: schemeId ?? this.schemeId,
        observations: observations ?? this.observations,
        gradedAnswers: gradedAnswers ?? this.gradedAnswers,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
        preSegmentedAnswers: preSegmentedAnswers,
      );

  factory MarkingScript.fromJson(Map<String, dynamic> json) {
    // Back-compat for scripts saved before firstName/surname/gender/
    // subjectName/gradeName existed (single combined "studentName", no
    // gender or subject/grade at all) — split on the first space as a
    // best-effort migration rather than failing to load an older script
    // outright. Genuinely unknown fields fall back to placeholders a
    // teacher can immediately see and fix, never to a silent guess that
    // looks like real data.
    final legacyName = json['studentName'] as String?;
    String firstName;
    String surname;
    if (json['firstName'] != null || json['surname'] != null) {
      firstName = json['firstName'] as String? ?? '';
      surname = json['surname'] as String? ?? '';
    } else if (legacyName != null && legacyName.trim().isNotEmpty) {
      final parts = legacyName.trim().split(RegExp(r'\s+'));
      firstName = parts.first;
      surname = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    } else {
      firstName = '';
      surname = '';
    }

    return MarkingScript(
      id: json['id'] as String,
      firstName: firstName,
      surname: surname,
      gender: CandidateGender.fromDb(json['gender'] as String? ?? 'male'),
      // Defaults true (not false) for back-compat: every script saved
      // before this field existed came from the form-based capture flow,
      // which always asked for gender explicitly - only the newer batch-
      // capture flow ever writes false, and it always writes it explicitly.
      genderConfirmed: json['genderConfirmed'] as bool? ?? true,
      studentIdNumber: json['studentIdNumber'] as String?,
      scriptNumber: json['scriptNumber'] as int,
      subjectName: json['subjectName'] as String? ?? 'Unknown subject',
      gradeName: json['gradeName'] as String? ?? 'Unknown grade',
      classLevel: json['classLevel'] as String? ?? '',
      pageFileNames: (json['pageFileNames'] as List).cast<String>(),
      photosDiscarded: json['photosDiscarded'] as bool? ?? false,
      capturedAt: DateTime.parse(json['capturedAt'] as String),
      status: MarkingScriptStatus.fromDb(json['status'] as String? ?? 'captured'),
      schemeId: json['schemeId'] as String?,
      gradedAnswers: (json['gradedAnswers'] as List?)
          ?.cast<Map<String, dynamic>>()
          .map(GradedAnswer.fromJson)
          .toList(),
      observations: (json['observations'] as List?)?.cast<String>(),
      lastError: json['lastError'] as String?,
      preSegmentedAnswers: (json['preSegmentedAnswers'] as List?)
          ?.cast<Map<String, dynamic>>()
          .map(PreSegmentedAnswer.fromJson)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'firstName': firstName,
        'surname': surname,
        'gender': gender.dbValue,
        'genderConfirmed': genderConfirmed,
        'studentIdNumber': studentIdNumber,
        'scriptNumber': scriptNumber,
        'subjectName': subjectName,
        'gradeName': gradeName,
        'classLevel': classLevel,
        'pageFileNames': pageFileNames,
        'photosDiscarded': photosDiscarded,
        'capturedAt': capturedAt.toIso8601String(),
        'status': status.dbValue,
        'schemeId': schemeId,
        'gradedAnswers': gradedAnswers?.map((a) => a.toJson()).toList(),
        'observations': observations,
        'lastError': lastError,
        'preSegmentedAnswers': preSegmentedAnswers?.map((s) => s.toJson()).toList(),
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
