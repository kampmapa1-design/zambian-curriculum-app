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

  const RosterNameMatch({required this.extractedName, this.extractedScore, this.matchedLearner});

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
  }) async {
    final db = await _db;
    final now = DateTime.now();
    final id = await db.insert('report_classes', {
      'school_name': schoolName.trim(),
      'class_grade': classGrade.trim(),
      'term': term.trim(),
      'created_at': now.toIso8601String(),
    });
    return ReportClass(id: id, schoolName: schoolName.trim(), classGrade: classGrade.trim(), term: term.trim(), createdAt: now);
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
        createdAt: DateTime.parse(r['created_at'] as String),
      );

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
        RosterNameMatch(
          extractedName: e.name,
          extractedScore: e.score,
          matchedLearner: byNormalizedName[normalize(e.name)],
        ),
    ];
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
        updatedAt: DateTime.parse(r['updated_at'] as String),
      );

  /// Upserts one learner's score (and, optionally, comment) for one
  /// subject. Rejects setting a score directly on a composite subject —
  /// its value is always computed, see [scoreFor].
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
    final db = await _db;
    await db.insert(
      'report_scores',
      {
        'learner_id': learnerId,
        'subject_id': subject.id,
        'score': score,
        'comment': comment,
        'comment_source': commentSource?.dbValue,
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
