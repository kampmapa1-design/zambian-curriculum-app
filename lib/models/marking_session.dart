/// A continuous, resumable AI-Assisted Marking capture session — subject/
/// grade, the marking scheme, and how many scripts the teacher plans to
/// capture, all set once at the very start (see ScriptBatchCaptureScreen)
/// and never re-asked for the rest of the session.
///
/// Persisted to disk (see MarkingSessionRepository), not kept only in a
/// screen's in-memory State — that distinction is the actual fix for a
/// real, reported bug (2026-09-03): a teacher capturing several scripts in
/// one sitting kept getting asked "what subject is this?" again after
/// every single script, because the previous "remember the last template/
/// scheme" mechanism lived only in MarkingQueueScreen's in-memory State,
/// which real Android backgrounding/process-death (common on budget
/// hardware, and the entire reason the whole app leaving-and-returning
/// scenario needs to work at all) can and does silently wipe. A session
/// persisted here survives exactly that: leaving the app mid-batch and
/// coming back lands the teacher right back where they left off — same
/// subject, same scheme, same running count — with nothing to re-enter.
class MarkingSession {
  /// Together with [subjectCode]/[gradeLevel], enough to reload the exact
  /// same SyllabusTemplate via TemplateRepository.loadSyllabus — see
  /// Curriculum.code/Subject.code/Grade.level.
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;

  /// Display-only — avoids reloading the template just to show a label
  /// while resuming.
  final String subjectName;
  final String gradeName;

  /// Enough to reload the exact same MarkingScheme via
  /// MarkingSchemeRepository.loadCatalog() + a lookup by id.
  final String schemeId;
  final String schemeTitle;

  /// How many scripts the teacher said, up front, they plan to capture in
  /// this session — the whole point of asking once instead of per script.
  final int targetScriptCount;

  /// The first MarkingScript.scriptNumber issued for this session —
  /// scriptNumber increments globally (see
  /// MarkingScriptRepository.nextScriptNumber), so "how many scripts have
  /// been captured in this session so far" is always
  /// `latestScriptNumber - startScriptNumber + 1`, with no separate
  /// counter to keep in sync.
  final int startScriptNumber;

  final DateTime startedAt;

  const MarkingSession({
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.subjectName,
    required this.gradeName,
    required this.schemeId,
    required this.schemeTitle,
    required this.targetScriptCount,
    required this.startScriptNumber,
    required this.startedAt,
  });

  /// How many scripts this session has captured so far, given the highest
  /// scriptNumber issued to any script belonging to it. Callers pass
  /// whatever the most recently captured script's own number is (or the
  /// next free number minus one, when nothing's been captured mid-way
  /// through setup) — see ScriptBatchCaptureScreen._onScriptCompleted.
  int capturedCountGiven(int latestScriptNumber) =>
      (latestScriptNumber - startScriptNumber + 1).clamp(0, 1 << 30);

  bool isCompleteGiven(int latestScriptNumber) => capturedCountGiven(latestScriptNumber) >= targetScriptCount;

  Map<String, dynamic> toJson() => {
        'curriculumCode': curriculumCode,
        'subjectCode': subjectCode,
        'gradeLevel': gradeLevel,
        'subjectName': subjectName,
        'gradeName': gradeName,
        'schemeId': schemeId,
        'schemeTitle': schemeTitle,
        'targetScriptCount': targetScriptCount,
        'startScriptNumber': startScriptNumber,
        'startedAt': startedAt.toIso8601String(),
      };

  factory MarkingSession.fromJson(Map<String, dynamic> json) => MarkingSession(
        curriculumCode: json['curriculumCode'] as String,
        subjectCode: json['subjectCode'] as String,
        gradeLevel: json['gradeLevel'] as int,
        subjectName: json['subjectName'] as String,
        gradeName: json['gradeName'] as String,
        schemeId: json['schemeId'] as String,
        schemeTitle: json['schemeTitle'] as String,
        targetScriptCount: json['targetScriptCount'] as int,
        startScriptNumber: json['startScriptNumber'] as int,
        startedAt: DateTime.parse(json['startedAt'] as String),
      );
}
