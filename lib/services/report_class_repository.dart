import 'package:sqflite/sqflite.dart';

import '../models/report_class.dart';
import 'database_helper.dart';

/// One extracted name, matched (or not) against an existing roster — the
/// result of [ReportClassRepository.matchNamesAgainstRoster], feeding
/// Stage 4's review screen: a matched name links straight to its real
/// learner; an unmatched one needs the teacher to either pick who it
/// really is or add them as a new roster entry. Never auto-links two
/// different-looking names on a guess — see that method's own doc comment.
class RosterNameMatch {
  final String extractedName;
  final String? extractedScore;
  final ReportLearner? matchedLearner;

  /// Only ever set when [matchedLearner] is null (no exact match) and the
  /// roster is non-empty — the single closest real roster name by edit
  /// distance, offered as a one-tap "Replace with closest match?"
  /// suggestion (see UploadScoreSheetFlow) instead of requiring the
  /// teacher to open the manual picker for every unclear OCR read. Never
  /// applied automatically — see [ReportClassRepository.matchNamesAgainstRoster]'s
  /// own doc comment on why an exact match is still required to auto-link.
  final ReportLearner? closestMatch;

  const RosterNameMatch({
    required this.extractedName,
    this.extractedScore,
    this.matchedLearner,
    this.closestMatch,
  });

  bool get isMatched => matchedLearner != null;
}

/// On-device SQLite storage for the Report Form Pipeline's class roster and
/// Broad Mark Sheet — a real, persistent class/learner/subject/score model,
/// distinct from [ClassProgressRepository]'s free-text class LABEL (which
/// is only ever a resume-cursor tag for Scheme of Work, never a roster).
/// Uses the same shared on-device database as everything else in this app
/// (`DatabaseHelper.instance.database`) but runs its own queries directly
/// rather than routing through `DatabaseHelper`'s own methods — this is a
/// self-contained subsystem, not entangled with curriculum-template import.
///
/// **Standing limits, enforced here in code (not the schema)**: at most 140
/// learners and 12 subject containers per class, matching the app's own
/// established convention of validating business-rule caps in the
/// repository/Cloud-Function layer rather than the database (see e.g.
/// generateSchemeOfWorkContent's 20-item request cap).
class ReportClassRepository {
  ReportClassRepository({DatabaseHelper? databaseHelper}) : _dbHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _dbHelper;

  static const maxLearners = 140;
  static const maxSubjects = 12;

  Future<Database> get _db async => _dbHelper.database;

  // -------------------------------------------------------------------
  // Classes
  // -------------------------------------------------------------------

  Future<ReportClass> createClass({
    required String schoolName,
    required String classGrade,
    required String term,
    ReportAssessmentSystem assessmentSystem = ReportAssessmentSystem.standaloneTest,
    String? backupEmail,
  }) async {
    final db = await _db;
    final now = DateTime.now();
    final id = await db.insert('report_classes', {
      'school_name': schoolName.trim(),
      'class_grade': classGrade.trim(),
      'term': term.trim(),
      'assessment_system': assessmentSystem.dbValue,
      'backup_email': backupEmail == null || backupEmail.trim().isEmpty ? null : backupEmail.trim(),
      'created_at': now.toIso8601String(),
    });
    return ReportClass(
      id: id,
      schoolName: schoolName.trim(),
      classGrade: classGrade.trim(),
      term: term.trim(),
      assessmentSystem: assessmentSystem,
      backupEmail: backupEmail,
      createdAt: now,
    );
  }

  /// Confirmed once, the first time real score entry starts for a
  /// Continuous Assessment class (see UploadScoreSheetFlow) — not at
  /// Class Setup itself, per explicit request. [testWeightPercent] +
  /// [examWeightPercent] must sum to 100.
  Future<void> confirmCaWeights(int classId, {required int testWeightPercent, required int examWeightPercent}) async {
    if (testWeightPercent + examWeightPercent != 100) {
      throw ArgumentError('C.A. weights must sum to 100 (got $testWeightPercent + $examWeightPercent).');
    }
    final db = await _db;
    await db.update(
      'report_classes',
      {'ca_test_weight_percent': testWeightPercent, 'ca_exam_weight_percent': examWeightPercent},
      where: 'id = ?',
      whereArgs: [classId],
    );
  }

  /// Sets or clears where this class's backups are emailed — see
  /// ReportClassBackupService. Never required for anything else in this
  /// pipeline to keep working.
  Future<void> updateBackupEmail(int classId, String? backupEmail) async {
    final db = await _db;
    await db.update(
      'report_classes',
      {'backup_email': backupEmail == null || backupEmail.trim().isEmpty ? null : backupEmail.trim()},
      where: 'id = ?',
      whereArgs: [classId],
    );
  }

  Future<List<ReportClass>> listClasses() async {
    final db = await _db;
    final rows = await db.query('report_classes', orderBy: 'created_at DESC');
    return [for (final r in rows) _classFromRow(r)];
  }

  Future<ReportClass?> getClass(int classId) async {
    final db = await _db;
    final rows = await db.query('report_classes', where: 'id = ?', whereArgs: [classId], limit: 1);
    return rows.isEmpty ? null : _classFromRow(rows.first);
  }

  ReportClass _classFromRow(Map<String, Object?> r) => ReportClass(
        id: r['id'] as int,
        schoolName: r['school_name'] as String,
        classGrade: r['class_grade'] as String,
        term: r['term'] as String,
        assessmentSystem: ReportAssessmentSystem.fromDb(r['assessment_system'] as String?),
        caTestWeightPercent: r['ca_test_weight_percent'] as int?,
        caExamWeightPercent: r['ca_exam_weight_percent'] as int?,
        backupEmail: r['backup_email'] as String?,
        reportFormsCompletedAt:
            r['report_forms_completed_at'] == null ? null : DateTime.parse(r['report_forms_completed_at'] as String),
        createdAt: DateTime.parse(r['created_at'] as String),
      );

  /// Marks this class's report-form preparation as complete — unlocks the
  /// consolidated Analysis table (see ReportFormAnalysisScreen). Scores
  /// remain fully editable after this; see [setScore]/[setComponentScore]
  /// for how a post-completion edit gets flagged.
  Future<void> markReportFormsCompleted(int classId) async {
    final db = await _db;
    await db.update(
      'report_classes',
      {'report_forms_completed_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [classId],
    );
  }

  Future<void> deleteClass(int classId) async {
    final db = await _db;
    await db.delete('report_classes', where: 'id = ?', whereArgs: [classId]);
  }

  // -------------------------------------------------------------------
  // Learners / roster
  // -------------------------------------------------------------------

  Future<List<ReportLearner>> listLearners(int classId) async {
    final db = await _db;
    final rows = await db.query('report_learners', where: 'class_id = ?', whereArgs: [classId], orderBy: 'roster_order');
    return [for (final r in rows) _learnerFromRow(r)];
  }

  ReportLearner _learnerFromRow(Map<String, Object?> r) => ReportLearner(
        id: r['id'] as int,
        classId: r['class_id'] as int,
        fullName: r['full_name'] as String,
        rosterOrder: r['roster_order'] as int,
        guardianEmail: r['guardian_email'] as String?,
        guardianPhone: r['guardian_phone'] as String?,
      );

  /// Adds one learner at the end of the roster — Stage 6's "Omitted Entry"
  /// (a learner missed during bulk upload) and manual roster building both
  /// go through this. Throws [StateError] past [maxLearners].
  Future<ReportLearner> addLearner(int classId, String fullName) async {
    final db = await _db;
    final existing = await listLearners(classId);
    if (existing.length >= maxLearners) {
      throw StateError('This class already has the maximum of $maxLearners learners.');
    }
    final nextOrder = existing.isEmpty ? 1 : existing.map((l) => l.rosterOrder).reduce((a, b) => a > b ? a : b) + 1;
    final id = await db.insert('report_learners', {
      'class_id': classId,
      'full_name': fullName.trim(),
      'roster_order': nextOrder,
      'created_at': DateTime.now().toIso8601String(),
    });
    return ReportLearner(id: id, classId: classId, fullName: fullName.trim(), rosterOrder: nextOrder);
  }

  /// Stage 7 — "Update Learner Data": corrects a name after the "Edit?"
  /// confirmation. Does not touch that learner's scores.
  Future<void> renameLearner(int learnerId, String newFullName) async {
    final db = await _db;
    await db.update('report_learners', {'full_name': newFullName.trim()}, where: 'id = ?', whereArgs: [learnerId]);
  }

  /// Removes one learner and every one of their real scores (cascades via
  /// `ON DELETE CASCADE`) — never any other learner's data. Reached only
  /// through BroadMarkSheetScreen's own two-step confirmation ("Delete?"
  /// then "sure you want to delete") — this method itself performs no
  /// confirmation of its own, that's the caller's job.
  Future<void> deleteLearner(int learnerId) async {
    final db = await _db;
    await db.delete('report_learners', where: 'id = ?', whereArgs: [learnerId]);
  }

  /// Stage 15's send-target fields — a guardian's email/phone, both
  /// optional, both editable from the same Stage 7 "Edit?" screen. Empty
  /// string is treated the same as null (clears the field) rather than
  /// stored as a real value.
  Future<void> updateGuardianContact(int learnerId, {String? email, String? phone}) async {
    final db = await _db;
    await db.update(
      'report_learners',
      {
        'guardian_email': (email == null || email.trim().isEmpty) ? null : email.trim(),
        'guardian_phone': (phone == null || phone.trim().isEmpty) ? null : phone.trim(),
      },
      where: 'id = ?',
      whereArgs: [learnerId],
    );
  }

  /// Stage 2 — roster establishment/matching. On the FIRST subject upload
  /// for a class (empty roster), every extracted name becomes a new
  /// roster entry, in the order extracted — this photograph genuinely IS
  /// the roster being created. On every later upload, each extracted name
  /// is matched against the EXISTING roster by exact, normalized name only
  /// (trimmed, collapsed whitespace, case-insensitive) — never a fuzzy/
  /// best-guess match, since silently linking two different-looking names
  /// risks attributing one learner's score to another. An unmatched name
  /// is returned with `matchedLearner: null` for the teacher to resolve on
  /// Stage 4's review screen (link to an existing learner, or add as a
  /// genuinely missed roster entry) — never auto-resolved here.
  Future<List<RosterNameMatch>> matchNamesAgainstRoster(
    int classId,
    List<({String name, String? score})> extracted,
  ) async {
    final roster = await listLearners(classId);
    if (roster.isEmpty) {
      // This upload establishes the roster.
      final created = <RosterNameMatch>[];
      for (final e in extracted) {
        final learner = await addLearner(classId, e.name);
        created.add(RosterNameMatch(extractedName: e.name, extractedScore: e.score, matchedLearner: learner));
      }
      return created;
    }

    String normalize(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final byNormalizedName = {for (final l in roster) normalize(l.fullName): l};

    return [
      for (final e in extracted)
        () {
          final matched = byNormalizedName[normalize(e.name)];
          return RosterNameMatch(
            extractedName: e.name,
            extractedScore: e.score,
            matchedLearner: matched,
            closestMatch: matched == null ? _closestRosterMatch(e.name, roster) : null,
          );
        }(),
    ];
  }

  /// The single closest real roster name to [extractedName] by edit
  /// distance, only offered when it's genuinely close (distance no more
  /// than a fifth of the extracted name's own length, minimum 2 — a real,
  /// plausible OCR misread, e.g. "Chnisha Banda" vs "Chanisha Banda", not
  /// a wildly different name). Returns null when nothing is close enough
  /// to suggest — the teacher still has the full manual-pick option for
  /// those, this is only ever a shortcut, never the only path.
  ReportLearner? _closestRosterMatch(String extractedName, List<ReportLearner> roster) {
    final needle = extractedName.trim().toLowerCase();
    if (needle.isEmpty || roster.isEmpty) return null;
    ReportLearner? best;
    var bestDistance = 1 << 30;
    for (final learner in roster) {
      final distance = _levenshteinDistance(needle, learner.fullName.trim().toLowerCase());
      if (distance < bestDistance) {
        bestDistance = distance;
        best = learner;
      }
    }
    final threshold = (needle.length / 5).ceil().clamp(2, 6);
    return bestDistance <= threshold ? best : null;
  }

  int _levenshteinDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var previousRow = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final currentRow = List<int>.filled(b.length + 1, 0);
      currentRow[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final deletionCost = previousRow[j + 1] + 1;
        final insertionCost = currentRow[j] + 1;
        final substitutionCost = previousRow[j] + (a[i] == b[j] ? 0 : 1);
        currentRow[j + 1] = [deletionCost, insertionCost, substitutionCost].reduce((x, y) => x < y ? x : y);
      }
      previousRow = currentRow;
    }
    return previousRow[b.length];
  }

  // -------------------------------------------------------------------
  // Subjects
  // -------------------------------------------------------------------

  Future<List<ReportSubject>> listSubjects(int classId) async {
    final db = await _db;
    final rows = await db.query('report_subjects', where: 'class_id = ?', whereArgs: [classId], orderBy: 'sequence_number');
    return [for (final r in rows) _subjectFromRow(r)];
  }

  ReportSubject _subjectFromRow(Map<String, Object?> r) => ReportSubject(
        id: r['id'] as int,
        classId: r['class_id'] as int,
        name: r['name'] as String,
        sequenceNumber: r['sequence_number'] as int,
        isComposite: (r['is_composite'] as int) == 1,
        compositePartAId: r['composite_part_a_id'] as int?,
        compositePartBId: r['composite_part_b_id'] as int?,
      );

  /// Adds a plain (non-composite) subject container, or finds it if one
  /// with this exact name already exists on this class (subsequent uploads
  /// for the same subject reuse the same container, never duplicate it).
  /// Throws [StateError] past [maxSubjects].
  Future<ReportSubject> getOrCreateSubject(int classId, String name) async {
    final existing = await listSubjects(classId);
    final normalized = name.trim().toLowerCase();
    final match = existing.where((s) => s.name.trim().toLowerCase() == normalized).firstOrNull;
    if (match != null) return match;

    if (existing.length >= maxSubjects) {
      throw StateError('This class already has the maximum of $maxSubjects subjects.');
    }
    final db = await _db;
    final nextSeq = existing.isEmpty ? 1 : existing.map((s) => s.sequenceNumber).reduce((a, b) => a > b ? a : b) + 1;
    final id = await db.insert('report_subjects', {
      'class_id': classId,
      'name': name.trim(),
      'sequence_number': nextSeq,
      'is_composite': 0,
    });
    return ReportSubject(id: id, classId: classId, name: name.trim(), sequenceNumber: nextSeq);
  }

  /// Stage 5 — Composite Subject: creates a subject container whose score
  /// is always the sum of two other REAL (non-composite) subjects already
  /// on this class — never manually editable (see [scoreFor]). Rejects a
  /// part that's itself composite (no composite-of-composites) or that
  /// belongs to a different class.
  Future<ReportSubject> createCompositeSubject({
    required int classId,
    required String name,
    required ReportSubject partA,
    required ReportSubject partB,
  }) async {
    if (partA.classId != classId || partB.classId != classId) {
      throw ArgumentError('Both parts of a composite subject must belong to the same class.');
    }
    if (partA.isComposite || partB.isComposite) {
      throw ArgumentError('A composite subject cannot be built from another composite subject.');
    }
    final existing = await listSubjects(classId);
    if (existing.length >= maxSubjects) {
      throw StateError('This class already has the maximum of $maxSubjects subjects.');
    }
    final db = await _db;
    final nextSeq = existing.isEmpty ? 1 : existing.map((s) => s.sequenceNumber).reduce((a, b) => a > b ? a : b) + 1;
    final id = await db.insert('report_subjects', {
      'class_id': classId,
      'name': name.trim(),
      'sequence_number': nextSeq,
      'is_composite': 1,
      'composite_part_a_id': partA.id,
      'composite_part_b_id': partB.id,
    });
    return ReportSubject(
      id: id,
      classId: classId,
      name: name.trim(),
      sequenceNumber: nextSeq,
      isComposite: true,
      compositePartAId: partA.id,
      compositePartBId: partB.id,
    );
  }

  // -------------------------------------------------------------------
  // Scores
  // -------------------------------------------------------------------

  Future<ReportScore?> getScore(int learnerId, int subjectId) async {
    final db = await _db;
    final rows = await db.query(
      'report_scores',
      where: 'learner_id = ? AND subject_id = ?',
      whereArgs: [learnerId, subjectId],
      limit: 1,
    );
    return rows.isEmpty ? null : _scoreFromRow(rows.first);
  }

  ReportScore _scoreFromRow(Map<String, Object?> r) => ReportScore(
        id: r['id'] as int,
        learnerId: r['learner_id'] as int,
        subjectId: r['subject_id'] as int,
        score: (r['score'] as num?)?.toDouble(),
        comment: r['comment'] as String?,
        commentSource: ReportCommentSource.fromDb(r['comment_source'] as String?),
        caTestScore: (r['ca_test_score'] as num?)?.toDouble(),
        caExamScore: (r['ca_exam_score'] as num?)?.toDouble(),
        editedAfterCompletionAt:
            r['edited_after_completion_at'] == null ? null : DateTime.parse(r['edited_after_completion_at'] as String),
        updatedAt: DateTime.parse(r['updated_at'] as String),
      );

  /// True the moment a write needs flagging as a post-completion edit —
  /// see [ReportScore.editedAfterCompletionAt]'s own doc comment. Once a
  /// score has ever been flagged, later writes keep re-stamping the
  /// timestamp to the latest edit (never clears it back to null — there's
  /// no "un-complete a class" action for this to need to undo).
  Future<DateTime?> _editStampFor(int classId, DateTime? existingStamp) async {
    if (existingStamp != null) return DateTime.now();
    final reportClass = await getClass(classId);
    return (reportClass?.isReportFormsCompleted ?? false) ? DateTime.now() : null;
  }

  /// Upserts one learner's score (and, optionally, comment) for one
  /// STANDALONE-TEST subject. Rejects setting a score directly on a
  /// composite subject — its value is always computed, see [scoreFor].
  /// For a Continuous Assessment subject, use [setComponentScore] instead
  /// — this defensively preserves any existing Test/Exam component values
  /// already stored (rather than wiping them) if it's ever called on one
  /// anyway, but the real entry point for C.A. score entry is
  /// [setComponentScore].
  Future<void> setScore({
    required int learnerId,
    required ReportSubject subject,
    double? score,
    String? comment,
    ReportCommentSource? commentSource,
  }) async {
    if (subject.isComposite) {
      throw ArgumentError("Composite subject '${subject.name}' cannot have a score set directly.");
    }
    final existing = await getScore(learnerId, subject.id);
    final editStamp = await _editStampFor(subject.classId, existing?.editedAfterCompletionAt);
    final db = await _db;
    await db.insert(
      'report_scores',
      {
        'learner_id': learnerId,
        'subject_id': subject.id,
        'score': score,
        'comment': comment,
        'comment_source': commentSource?.dbValue,
        'ca_test_score': existing?.caTestScore,
        'ca_exam_score': existing?.caExamScore,
        'edited_after_completion_at': editStamp?.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Upserts one real Continuous Assessment component (Test or Exam) for
  /// one (learner, subject) — the real entry point for C.A. score entry
  /// (see UploadScoreSheetFlow's component picker). Recomputes the
  /// subject's own `score` as the weighted sum the moment BOTH components
  /// are present and [reportClass]'s weights are confirmed; leaves `score`
  /// null otherwise — never treats a missing component as zero, same
  /// "don't guess a missing part" rule as a Composite Subject.
  Future<void> setComponentScore({
    required int learnerId,
    required ReportSubject subject,
    required ReportClass reportClass,
    required ReportCaComponent component,
    required double value,
  }) async {
    if (subject.isComposite) {
      throw ArgumentError("Composite subject '${subject.name}' cannot have a score set directly.");
    }
    final existing = await getScore(learnerId, subject.id);
    final testScore = component == ReportCaComponent.test ? value : existing?.caTestScore;
    final examScore = component == ReportCaComponent.exam ? value : existing?.caExamScore;
    double? finalScore;
    if (testScore != null && examScore != null && reportClass.hasConfirmedCaWeights) {
      finalScore = testScore * reportClass.caTestWeightPercent! / 100 + examScore * reportClass.caExamWeightPercent! / 100;
    }
    final editStamp = existing?.editedAfterCompletionAt != null
        ? DateTime.now()
        : (reportClass.isReportFormsCompleted ? DateTime.now() : null);
    final db = await _db;
    await db.insert(
      'report_scores',
      {
        'learner_id': learnerId,
        'subject_id': subject.id,
        'score': finalScore,
        'comment': existing?.comment,
        'comment_source': existing?.commentSource?.dbValue,
        'ca_test_score': testScore,
        'ca_exam_score': examScore,
        'edited_after_completion_at': editStamp?.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Upserts only a score row's comment, leaving score/ca_test_score/
  /// ca_exam_score exactly as they already are — the Continuous Assessment
  /// counterpart to [setScore]'s combined score+comment write, since
  /// [setComponentScore] only ever touches one component at a time and
  /// never touches the comment. Also the right call for a standalone-test
  /// subject's comment-only edit, without re-writing a score that hasn't
  /// actually changed.
  Future<void> setComment({
    required int learnerId,
    required ReportSubject subject,
    String? comment,
    ReportCommentSource? commentSource,
  }) async {
    if (subject.isComposite) {
      throw ArgumentError("Composite subject '${subject.name}' cannot have a comment set directly.");
    }
    final existing = await getScore(learnerId, subject.id);
    final editStamp = await _editStampFor(subject.classId, existing?.editedAfterCompletionAt);
    final db = await _db;
    await db.insert(
      'report_scores',
      {
        'learner_id': learnerId,
        'subject_id': subject.id,
        'score': existing?.score,
        'comment': comment,
        'comment_source': commentSource?.dbValue,
        'ca_test_score': existing?.caTestScore,
        'ca_exam_score': existing?.caExamScore,
        'edited_after_completion_at': editStamp?.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The real, effective score for (learner, subject) — for a composite
  /// subject, always `scoreFor(part A) + scoreFor(part B)` (null if either
  /// part has no score yet, rather than treating a missing part as zero);
  /// for a plain subject, whatever's stored in `report_scores`.
  Future<double?> scoreFor(int learnerId, ReportSubject subject, {List<ReportSubject>? allSubjects}) async {
    if (!subject.isComposite) {
      final row = await getScore(learnerId, subject.id);
      return row?.score;
    }
    final subjects = allSubjects ?? await listSubjects(subject.classId);
    final partA = subjects.where((s) => s.id == subject.compositePartAId).firstOrNull;
    final partB = subjects.where((s) => s.id == subject.compositePartBId).firstOrNull;
    if (partA == null || partB == null) return null;
    final a = await scoreFor(learnerId, partA, allSubjects: subjects);
    final b = await scoreFor(learnerId, partB, allSubjects: subjects);
    if (a == null || b == null) return null;
    return a + b;
  }

  // -------------------------------------------------------------------
  // Class position / rank — Stage 10's "auto-computing class position"
  // -------------------------------------------------------------------

  /// Every learner's aggregate score (sum of every subject container that
  /// isn't itself a PART of some other composite subject on this class —
  /// a composite's own two parts are entered separately for the composite
  /// score to be computed FROM, but only the composite's combined figure
  /// is meant to count as its own graded subject on a report; counting
  /// the parts too would double-count that same subject's worth). Null in
  /// the map for a learner with no scores recorded on any counted subject
  /// yet — excluded from ranking, never treated as zero.
  Future<Map<int, double?>> aggregateScores(int classId) async {
    final learners = await listLearners(classId);
    final subjects = await listSubjects(classId);
    final partIds = {
      for (final s in subjects)
        if (s.isComposite) ...[
          if (s.compositePartAId != null) s.compositePartAId!,
          if (s.compositePartBId != null) s.compositePartBId!,
        ],
    };
    final countedSubjects = subjects.where((s) => !partIds.contains(s.id)).toList();

    final result = <int, double?>{};
    for (final learner in learners) {
      double? total;
      var any = false;
      for (final subject in countedSubjects) {
        final score = await scoreFor(learner.id, subject, allSubjects: subjects);
        if (score == null) continue;
        any = true;
        total = (total ?? 0) + score;
      }
      result[learner.id] = any ? total : null;
    }
    return result;
  }

  /// Competition ranking (1, 2, 2, 4 — two tied learners share the same
  /// position, the next learner's position accounts for both of them),
  /// the real convention for a school report card's "Position in Class".
  /// A learner with no aggregate score yet gets no entry in the returned
  /// map at all, rather than an arbitrary last place.
  Future<Map<int, int>> classPositions(int classId) async {
    final scores = await aggregateScores(classId);
    return _rankScores(scores);
  }

  /// Same competition-ranking convention as [classPositions], but WITHIN
  /// one [subject] alone rather than the whole-class aggregate — the
  /// per-subject "Position in Class" column some real report form
  /// layouts use (2026-09-04, per explicit request, matching a real
  /// uploaded report form template). A learner with no score yet for
  /// this specific subject gets no entry, same "don't guess" rule as
  /// [classPositions].
  Future<Map<int, int>> subjectPositions(int classId, ReportSubject subject, {List<ReportSubject>? allSubjects}) async {
    final learners = await listLearners(classId);
    final subjects = allSubjects ?? await listSubjects(classId);
    final scores = <int, double?>{};
    for (final learner in learners) {
      scores[learner.id] = await scoreFor(learner.id, subject, allSubjects: subjects);
    }
    return _rankScores(scores);
  }

  Map<int, int> _rankScores(Map<int, double?> scores) {
    final ranked = scores.entries.where((e) => e.value != null).toList()
      ..sort((a, b) => b.value!.compareTo(a.value!));
    final positions = <int, int>{};
    for (var i = 0; i < ranked.length; i++) {
      if (i > 0 && ranked[i].value == ranked[i - 1].value) {
        positions[ranked[i].key] = positions[ranked[i - 1].key]!;
      } else {
        positions[ranked[i].key] = i + 1;
      }
    }
    return positions;
  }

  // -------------------------------------------------------------------
  // Broad Mark Sheet — everything for one class in one call
  // -------------------------------------------------------------------

  Future<BroadMarkSheet> loadBroadMarkSheet(int classId) async {
    final reportClass = await getClass(classId);
    if (reportClass == null) {
      throw StateError('Class $classId no longer exists.');
    }
    final learners = await listLearners(classId);
    final subjects = await listSubjects(classId);

    final db = await _db;
    final learnerIds = learners.map((l) => l.id).toList();
    final scoresByKey = <String, ReportScore>{};
    if (learnerIds.isNotEmpty) {
      final placeholders = List.filled(learnerIds.length, '?').join(',');
      final rows = await db.query('report_scores', where: 'learner_id IN ($placeholders)', whereArgs: learnerIds);
      for (final r in rows) {
        final score = _scoreFromRow(r);
        scoresByKey[BroadMarkSheet.scoreKey(score.learnerId, score.subjectId)] = score;
      }
    }

    return BroadMarkSheet(reportClass: reportClass, learners: learners, subjects: subjects, scoresByKey: scoresByKey);
  }
}
