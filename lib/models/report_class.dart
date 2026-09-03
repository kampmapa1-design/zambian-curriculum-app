/// One school-year class the Report Form Pipeline (Grade Teacher) manages —
/// School Name / Class-Grade / Term, plus its own roster and subjects. See
/// ReportClassRepository for how these relate.
class ReportClass {
  final int id;
  final String schoolName;
  final String classGrade;
  final String term;
  final DateTime createdAt;

  const ReportClass({
    required this.id,
    required this.schoolName,
    required this.classGrade,
    required this.term,
    required this.createdAt,
  });

  String get label => '$classGrade — $schoolName ($term)';
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

  const ReportLearner({
    required this.id,
    required this.classId,
    required this.fullName,
    required this.rosterOrder,
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
  final double? score;
  final String? comment;
  final ReportCommentSource? commentSource;
  final DateTime updatedAt;

  const ReportScore({
    required this.id,
    required this.learnerId,
    required this.subjectId,
    this.score,
    this.comment,
    this.commentSource,
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
