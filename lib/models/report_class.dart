/// One school-year class the Report Form Pipeline (Grade Teacher) manages —
/// School Name / Class-Grade / Term, plus its own roster and subjects. See
/// ReportClassRepository for how these relate.
class ReportClass {
  final int id;
  final String schoolName;
  final String classGrade;
  final String term;
  final DateTime createdAt;

  /// Whether this class's real scores come from Continuous Assessment
  /// (a weighted Test + End-of-Term Exam per subject) or a single
  /// standalone score per subject — asked on Class Setup's first page,
  /// per explicit request, since it changes the report form's own layout
  /// (see ReportFormDocumentService) and how score entry works (see
  /// UploadScoreSheetFlow/ReportClassRepository.setComponentScore).
  final ReportAssessmentSystem assessmentSystem;

  /// Only set once, for a [ReportAssessmentSystem.continuousAssessment]
  /// class — confirmed the first time score entry actually starts for
  /// this class (see UploadScoreSheetFlow), not at Class Setup itself,
  /// per explicit request ("at the beginning of data entry for report
  /// forms"). Always sum to 100 when both are set. Null on a standalone-
  /// test class, or a C.A. class whose first upload hasn't happened yet.
  final int? caTestWeightPercent;
  final int? caExamWeightPercent;

  /// Where a full backup of this class (roster + Broad Mark Sheet, on
  /// every real checkpoint — see ReportClassBackupService) is emailed,
  /// alongside the on-device copy that already always exists. Optional;
  /// its absence never blocks any real work, only prompts a reminder.
  final String? backupEmail;

  /// Set once, when the Broad Mark Sheet's own "Mark Report Forms
  /// Complete" button is pressed (see BroadMarkSheetScreen) — unlocks the
  /// consolidated Analysis table. Scores can still be edited after this is
  /// set; any such edit is what [ReportScore.editedAfterCompletionAt]
  /// flags in red on the mark sheet, per explicit request. Null means the
  /// class hasn't been marked complete yet.
  final DateTime? reportFormsCompletedAt;

  const ReportClass({
    required this.id,
    required this.schoolName,
    required this.classGrade,
    required this.term,
    required this.createdAt,
    this.assessmentSystem = ReportAssessmentSystem.standaloneTest,
    this.caTestWeightPercent,
    this.caExamWeightPercent,
    this.backupEmail,
    this.reportFormsCompletedAt,
  });

  String get label => '$classGrade — $schoolName ($term)';

  bool get isContinuousAssessment => assessmentSystem == ReportAssessmentSystem.continuousAssessment;

  bool get isReportFormsCompleted => reportFormsCompletedAt != null;

  /// True once this C.A. class's Test/Exam weighting has actually been
  /// confirmed — see [caTestWeightPercent]'s own doc comment. Always
  /// false for a standalone-test class (there's nothing to confirm).
  bool get hasConfirmedCaWeights => isContinuousAssessment && caTestWeightPercent != null && caExamWeightPercent != null;

  ReportClass copyWith({
    ReportAssessmentSystem? assessmentSystem,
    int? caTestWeightPercent,
    int? caExamWeightPercent,
    String? backupEmail,
    DateTime? reportFormsCompletedAt,
  }) =>
      ReportClass(
        id: id,
        schoolName: schoolName,
        classGrade: classGrade,
        term: term,
        createdAt: createdAt,
        assessmentSystem: assessmentSystem ?? this.assessmentSystem,
        caTestWeightPercent: caTestWeightPercent ?? this.caTestWeightPercent,
        caExamWeightPercent: caExamWeightPercent ?? this.caExamWeightPercent,
        backupEmail: backupEmail ?? this.backupEmail,
        // Preserved unless explicitly overridden — dropping this silently on
        // any unrelated copyWith() would un-flag an already-completed class.
        reportFormsCompletedAt: reportFormsCompletedAt ?? this.reportFormsCompletedAt,
      );
}

/// Whether a class's real scores are entered as a single standalone score
/// per subject, or as a weighted Continuous Assessment Test + End-of-Term
/// Exam — see [ReportClass.assessmentSystem].
enum ReportAssessmentSystem {
  continuousAssessment,
  standaloneTest;

  String get dbValue => name;

  static ReportAssessmentSystem fromDb(String? value) => switch (value) {
        'continuousAssessment' => ReportAssessmentSystem.continuousAssessment,
        _ => ReportAssessmentSystem.standaloneTest,
      };
}

/// Which real component of a Continuous Assessment class's score a given
/// score-sheet upload represents — see UploadScoreSheetFlow's own
/// component-picker step and ReportClassRepository.setComponentScore.
enum ReportCaComponent {
  test,
  exam;

  String get label => this == ReportCaComponent.test ? 'Continuous Assessment Test' : 'End-of-Term Exam';
}

/// One learner on a [ReportClass]'s roster. [rosterOrder] is the stable
/// position established when the roster was first built (see
/// ReportClassRepository.matchOrCreateLearners) — every subsequent subject
/// upload matches against this order/name rather than re-asking for names.
class ReportLearner {
  final int id;
  final int classId;
  final String fullName;
  final int rosterOrder;

  /// Stage 15's send target — set via LearnerEditScreen (Stage 7),
  /// entirely optional. Both null is a normal, common state (nothing has
  /// stopped working before this point without them); Stage 15's send
  /// screen simply asks for a recipient at send time when neither is set,
  /// same as Assignment/Test Submission already do for their own email.
  final String? guardianEmail;
  final String? guardianPhone;

  const ReportLearner({
    required this.id,
    required this.classId,
    required this.fullName,
    required this.rosterOrder,
    this.guardianEmail,
    this.guardianPhone,
  });
}

/// One subject container on a [ReportClass]'s Broad Mark Sheet (max 12 per
/// class — enforced in ReportClassRepository, not the schema). A composite
/// subject (e.g. "Science" = Physics + Chemistry) has no score of its own —
/// [ReportClassRepository.scoreFor] always computes it as the sum of
/// [compositePartAId]/[compositePartBId]'s own scores, so it can never
/// manually be edited or drift out of sync with its two real parts.
class ReportSubject {
  final int id;
  final int classId;
  final String name;
  final int sequenceNumber;
  final bool isComposite;
  final int? compositePartAId;
  final int? compositePartBId;

  const ReportSubject({
    required this.id,
    required this.classId,
    required this.name,
    required this.sequenceNumber,
    this.isComposite = false,
    this.compositePartAId,
    this.compositePartBId,
  });
}

/// Where a score's comment came from — 'auto' (Stage 8's deterministic
/// score-band lookup, still fully editable) or 'manual' (a teacher typed
/// it themselves). Null on [ReportScore.commentSource] means no comment
/// has been set yet at all.
enum ReportCommentSource {
  auto,
  manual;

  String get dbValue => name;

  static ReportCommentSource? fromDb(String? value) => switch (value) {
        'auto' => ReportCommentSource.auto,
        'manual' => ReportCommentSource.manual,
        _ => null,
      };
}

/// One learner's score+comment for one (non-composite) subject. Never
/// exists for a composite subject — see [ReportSubject]'s own doc comment.
class ReportScore {
  final int id;
  final int learnerId;
  final int subjectId;

  /// For a standalone-test subject, the one real score. For a Continuous
  /// Assessment subject, the COMPUTED final ([caTestScore] × its weight +
  /// [caExamScore] × its weight) — always kept in sync by
  /// ReportClassRepository.setComponentScore, never set directly for a
  /// C.A. subject. Null whenever a C.A. subject is still missing either
  /// component (never treated as zero — same "don't guess a missing part"
  /// rule as a Composite Subject).
  final double? score;
  final String? comment;
  final ReportCommentSource? commentSource;

  /// Only meaningful for a [ReportAssessmentSystem.continuousAssessment]
  /// class — the real Continuous Assessment Test and End-of-Term Exam
  /// scores that [score] is computed from. Both null on a standalone-test
  /// class.
  final double? caTestScore;
  final double? caExamScore;

  /// Set only when this score was written or corrected AFTER the class's
  /// own [ReportClass.reportFormsCompletedAt] — the Broad Mark Sheet shows
  /// such a cell in red, with this timestamp on tap/hover, per explicit
  /// request ("if a cursor rests there or it is clicked on, it should show
  /// the date and time the edit... was done"). Null for every score
  /// entered before completion, or for a class never marked complete.
  final DateTime? editedAfterCompletionAt;

  final DateTime updatedAt;

  const ReportScore({
    required this.id,
    required this.learnerId,
    required this.subjectId,
    this.score,
    this.comment,
    this.commentSource,
    this.caTestScore,
    this.caExamScore,
    this.editedAfterCompletionAt,
    required this.updatedAt,
  });
}

/// The full Broad Mark Sheet for one class, loaded in a single call — every
/// learner, every subject container, and every stored score, keyed for fast
/// lookup by the mark-sheet screen and report-form generation alike.
class BroadMarkSheet {
  final ReportClass reportClass;
  final List<ReportLearner> learners;
  final List<ReportSubject> subjects;

  /// Keyed by 'learnerId_subjectId' — see [BroadMarkSheet.scoreKey].
  final Map<String, ReportScore> scoresByKey;

  const BroadMarkSheet({
    required this.reportClass,
    required this.learners,
    required this.subjects,
    required this.scoresByKey,
  });

  static String scoreKey(int learnerId, int subjectId) => '${learnerId}_$subjectId';

  ReportScore? scoreRowFor(int learnerId, int subjectId) => scoresByKey[scoreKey(learnerId, subjectId)];
}
