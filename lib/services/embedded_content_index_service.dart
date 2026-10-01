import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';

import '../models/embedded_content_segment.dart';
import 'database_helper.dart';
import 'embedded_content_index_builder.dart';
import 'embedded_lesson_plan_repository.dart';
import 'fine_tune_candidate_finder.dart';
import 'match_confidence_scorer.dart';
import 'text_excerpt_matching.dart' show keywordsOf;

/// Builds and queries the full-text index over every bundled embedded
/// lesson plan's real body content (Embedded Content Search, Stage 1,
/// 2026-09-22). Storage is SQLite ([DatabaseHelper]'s existing on-device
/// database), with an FTS5 virtual table used as a fast pre-filter when the
/// underlying SQLite build supports it. Stage 1's own dataset is small (the
/// bundled lesson plans amount to a few thousand segments at most), so
/// correctness never depends on FTS5 being available: when creating the
/// virtual table fails (some Android builds ship a system SQLite without
/// FTS5 compiled in), [search] transparently falls back to scoping by the
/// plain indexed columns and handing every segment in scope to
/// [MatchConfidenceScorer] directly — slower per call, never wrong, and the
/// caller never needs to know which path ran.
///
/// Entirely generic across whatever subjects/grades have embedded content:
/// nothing here names a specific subject — every scope comes from the
/// segments' own curriculum/subject/grade columns, themselves built
/// straight from each bundled set's own metadata (see
/// embedded_content_index_builder.dart). A newly bundled subject is
/// searchable the next time [ensureIndexed] rebuilds, with no code change.
class EmbeddedContentIndexService {
  EmbeddedContentIndexService({DatabaseHelper? databaseHelper, EmbeddedLessonPlanRepository? repository})
      : _dbHelper = databaseHelper ?? DatabaseHelper.instance,
        _repository = repository ?? EmbeddedLessonPlanRepository();

  final DatabaseHelper _dbHelper;
  final EmbeddedLessonPlanRepository _repository;

  static const _metaVersionKey = 'embedded_content_index_version';
  static const _ftsTable = 'embedded_content_fts';

  bool? _ftsAvailable;
  bool _ensured = false;

  /// Idempotent: cheap to call on every launch (mirrors
  /// SubjectContentRepository._seedBundledContent's own reasoning). Only
  /// actually rebuilds the stored index when the bundled content's own
  /// fingerprint has changed since the last build.
  Future<void> ensureIndexed({bool force = false}) async {
    if (_ensured && !force) return;
    final db = await _dbHelper.database;

    final sets = await _repository.allSets();
    final segments = buildEmbeddedContentSegments(sets);
    final version = _fingerprint(segments);

    final metaRows = await db.query('embedded_content_meta', where: 'key = ?', whereArgs: [_metaVersionKey], limit: 1);
    final storedVersion = metaRows.isEmpty ? null : metaRows.first['value'] as String?;

    if (!force && storedVersion == version) {
      _ftsAvailable ??= await _ensureFtsAvailability(db);
      _ensured = true;
      return;
    }

    await db.transaction((txn) async {
      await txn.delete('embedded_content_segments');
      final batch = txn.batch();
      for (final s in segments) {
        batch.insert('embedded_content_segments', s.toMap());
      }
      await batch.commit(noResult: true);
      await txn.insert(
        'embedded_content_meta',
        {'key': _metaVersionKey, 'value': version},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    _ftsAvailable = await _rebuildFts(db, segments);
    _ensured = true;
  }

  String _fingerprint(List<EmbeddedContentSegment> segments) {
    final totalChars = segments.fold<int>(0, (n, s) => n + s.text.length);
    return '${segments.length}:$totalChars';
  }

  Future<bool> _ensureFtsAvailability(Database db) async {
    final rows = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [_ftsTable]);
    return rows.isNotEmpty;
  }

  Future<bool> _rebuildFts(Database db, List<EmbeddedContentSegment> segments) async {
    try {
      await db.execute('DROP TABLE IF EXISTS $_ftsTable');
      await db.execute('''
        CREATE VIRTUAL TABLE $_ftsTable USING fts5(
          group_key UNINDEXED,
          curriculum_code UNINDEXED,
          subject_code UNINDEXED,
          grade_level UNINDEXED,
          text
        )
      ''');
      final batch = db.batch();
      for (final s in segments) {
        batch.insert(_ftsTable, {
          'group_key': s.groupKey,
          'curriculum_code': s.curriculumCode,
          'subject_code': s.subjectCode,
          'grade_level': s.gradeLevel,
          'text': s.text,
        });
      }
      await batch.commit(noResult: true);
      return true;
    } catch (error) {
      // No FTS5 support in this build's SQLite — search() falls back to a
      // plain-column scoped scan (see its own doc comment). Not fatal.
      debugPrint('EmbeddedContentIndexService: FTS5 unavailable, falling back to plain scan ($error)');
      try {
        await db.execute('DROP TABLE IF EXISTS $_ftsTable');
      } catch (_) {}
      return false;
    }
  }

  String? _ftsMatchExpression(String query) {
    final keywords = keywordsOf(query);
    if (keywords.isEmpty) return null;
    return keywords.map((k) => '"$k"').join(' OR ');
  }

  Future<List<EmbeddedContentSegment>> _segmentsInScope({
    String? curriculumCode,
    String? subjectCode,
    int? gradeLevel,
  }) async {
    final db = await _dbHelper.database;
    final where = <String>[];
    final args = <Object?>[];
    if (curriculumCode != null) {
      where.add('curriculum_code = ?');
      args.add(curriculumCode);
    }
    if (subjectCode != null) {
      where.add('subject_code = ?');
      args.add(subjectCode);
    }
    if (gradeLevel != null) {
      where.add('grade_level = ?');
      args.add(gradeLevel);
    }
    final rows = await db.query(
      'embedded_content_segments',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: where.isEmpty ? null : args,
    );
    return rows.map(EmbeddedContentSegment.fromMap).toList();
  }

  Future<List<EmbeddedContentSegment>> _candidateSegmentsFor(
    String query, {
    String? curriculumCode,
    String? subjectCode,
    int? gradeLevel,
  }) async {
    final db = await _dbHelper.database;

    if (_ftsAvailable == true) {
      final matchExpr = _ftsMatchExpression(query);
      if (matchExpr != null) {
        try {
          final where = <String>['$_ftsTable MATCH ?'];
          final args = <Object?>[matchExpr];
          if (curriculumCode != null) {
            where.add('curriculum_code = ?');
            args.add(curriculumCode);
          }
          if (subjectCode != null) {
            where.add('subject_code = ?');
            args.add(subjectCode);
          }
          if (gradeLevel != null) {
            where.add('grade_level = ?');
            args.add(gradeLevel);
          }
          final rows = await db.rawQuery(
            'SELECT DISTINCT group_key FROM $_ftsTable WHERE ${where.join(' AND ')}',
            args,
          );
          final groupKeys = {for (final r in rows) r['group_key'] as String};
          if (groupKeys.isEmpty) return const [];
          final placeholders = List.filled(groupKeys.length, '?').join(',');
          final segRows = await db.query('embedded_content_segments', where: 'group_key IN ($placeholders)', whereArgs: groupKeys.toList());
          return segRows.map(EmbeddedContentSegment.fromMap).toList();
        } catch (error) {
          debugPrint('EmbeddedContentIndexService: FTS5 query failed, falling back ($error)');
        }
      }
    }

    return _segmentsInScope(curriculumCode: curriculumCode, subjectCode: subjectCode, gradeLevel: gradeLevel);
  }

  /// Ranked content matches for a free-text [query] — Stage 3's search
  /// fallback. Scoped to a curriculum/subject/grade when the caller knows
  /// it (always used by [TopicSearchService]/[RequiredCoreTopicResolver],
  /// which know exactly which subject they're searching within).
  Future<List<ContentMatch>> search({
    required String query,
    String? curriculumCode,
    String? subjectCode,
    int? gradeLevel,
    int limit = 5,
  }) async {
    await ensureIndexed();
    final segments = await _candidateSegmentsFor(query, curriculumCode: curriculumCode, subjectCode: subjectCode, gradeLevel: gradeLevel);
    if (segments.isEmpty) return const [];
    final matches = const MatchConfidenceScorer().scoreAll(query: query, segments: segments);
    return matches.take(limit).toList();
  }

  /// Real embedded sub-topics bundled under [topicName] (Stage 6's "Fine
  /// Tune" button) — scoped to one curriculum/subject/grade, excluding any
  /// sub-topic already represented in [existingEntryNames] (normalized by
  /// the caller the same way [FineTuneCandidateFinder] does internally —
  /// see that class's own use of [normalizeHeadingKey]).
  Future<List<FineTuneCandidate>> fineTuneCandidatesForTopic({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required String topicName,
    required Set<String> existingEntryNames,
  }) async {
    await ensureIndexed();
    final db = await _dbHelper.database;
    final rows = await db.query(
      'embedded_content_segments',
      where: 'curriculum_code = ? AND subject_code = ? AND grade_level = ? AND LOWER(TRIM(topic_name)) = ?',
      whereArgs: [curriculumCode, subjectCode, gradeLevel, topicName.toLowerCase().trim()],
    );
    final segments = rows.map(EmbeddedContentSegment.fromMap).toList();
    return const FineTuneCandidateFinder().find(
      topicName: topicName,
      segmentsForTopic: segments,
      existingEntryNames: existingEntryNames,
    );
  }
}
