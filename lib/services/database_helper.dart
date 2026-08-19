import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/syllabus_models.dart';

/// Local SQLite storage for syllabus templates. Schema: curricula ->
/// subjects/grades/terms -> topics -> sub_topics -> learning_objectives /
/// competencies. A curriculum (e.g. the 2023 Competency-Based Curriculum or
/// the 2013 Outcome-Based Curriculum) owns its own subjects, grades, and
/// terms, so two curricula never share rows even when they reuse the same
/// subject code or grade name. Everything lives on device, so lookups work
/// fully offline.
class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

  static const _schemaVersion = 2;

  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'curriculum.db');
    return openDatabase(
      path,
      version: _schemaVersion,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) => _createSchema(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        // This app has no released user base yet, and the only local state
        // worth preserving (which topic a teacher last marked concluded) is
        // trivial to re-enter. Rather than hand-write incremental ALTER
        // TABLE migrations against SQLite's limited support for them
        // (can't add a UNIQUE constraint or a FK after the fact), just
        // rebuild the schema from scratch on every version bump.
        for (final table in _tableNamesNewestFirst) {
          await db.execute('DROP TABLE IF EXISTS $table');
        }
        await _createSchema(db);
      },
    );
  }

  // Drop order matters for foreign keys: children before parents.
  static const _tableNamesNewestFirst = [
    'topic_progress',
    'learning_objectives',
    'competencies',
    'sub_topics',
    'topics',
    'terms',
    'grades',
    'subjects',
    'curricula',
  ];

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE curricula (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        description TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE subjects (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        curriculum_id INTEGER NOT NULL REFERENCES curricula(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        code TEXT NOT NULL,
        description TEXT,
        UNIQUE (curriculum_id, code)
      )
    ''');
    await db.execute('''
      CREATE TABLE grades (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        curriculum_id INTEGER NOT NULL REFERENCES curricula(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        code TEXT NOT NULL,
        sequence_number INTEGER NOT NULL,
        phase TEXT,
        UNIQUE (curriculum_id, code)
      )
    ''');
    await db.execute('''
      CREATE TABLE terms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        curriculum_id INTEGER NOT NULL REFERENCES curricula(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        code TEXT NOT NULL,
        sequence_number INTEGER NOT NULL,
        UNIQUE (curriculum_id, code)
      )
    ''');
    await db.execute('''
      CREATE TABLE topics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        subject_id INTEGER NOT NULL REFERENCES subjects(id) ON DELETE CASCADE,
        grade_id INTEGER NOT NULL REFERENCES grades(id) ON DELETE CASCADE,
        term_id INTEGER NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        sequence_number INTEGER NOT NULL,
        description TEXT,
        UNIQUE (subject_id, grade_id, term_id, name)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_topics_scope_order ON topics (subject_id, grade_id, term_id, sequence_number)',
    );
    await db.execute('''
      CREATE TABLE sub_topics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        sequence_number INTEGER NOT NULL,
        description TEXT,
        UNIQUE (topic_id, name)
      )
    ''');
    await db.execute('''
      CREATE TABLE learning_objectives (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        topic_id INTEGER REFERENCES topics(id) ON DELETE CASCADE,
        sub_topic_id INTEGER REFERENCES sub_topics(id) ON DELETE CASCADE,
        sequence_number INTEGER NOT NULL,
        description TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE competencies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        topic_id INTEGER REFERENCES topics(id) ON DELETE CASCADE,
        sub_topic_id INTEGER REFERENCES sub_topics(id) ON DELETE CASCADE,
        sequence_number INTEGER NOT NULL,
        description TEXT NOT NULL,
        category TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE topic_progress (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        subject_id INTEGER NOT NULL REFERENCES subjects(id) ON DELETE CASCADE,
        grade_id INTEGER NOT NULL REFERENCES grades(id) ON DELETE CASCADE,
        last_concluded_topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
        updated_at TEXT NOT NULL,
        UNIQUE (subject_id, grade_id)
      )
    ''');
  }

  Future<int> _getOrCreate(
    DatabaseExecutor db,
    String table,
    Map<String, Object?> lookup,
    Map<String, Object?> defaults,
  ) async {
    final whereClause = lookup.keys.map((k) => '$k = ?').join(' AND ');
    final existing = await db.query(
      table,
      columns: ['id'],
      where: whereClause,
      whereArgs: lookup.values.toList(),
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return existing.first['id'] as int;
    }
    return db.insert(table, {...lookup, ...defaults});
  }

  Future<int?> _findObjectiveOrCompetency(
    DatabaseExecutor db,
    String table,
    String scopeColumn,
    int scopeId,
    String description,
  ) async {
    final rows = await db.query(
      table,
      columns: ['id'],
      where: '$scopeColumn = ? AND description = ?',
      whereArgs: [scopeId, description],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  /// Imports one bundled template JSON (see assets/syllabi/*.json) into the
  /// local database. Idempotent: safe to call every app launch without
  /// creating duplicate rows. Expects a top-level "curriculum" object
  /// ({code, name, description}) in addition to the existing subject/grade/
  /// terms shape.
  Future<void> importTemplate(Map<String, dynamic> json) async {
    final db = await database;
    await db.transaction((txn) async {
      final curriculumJson = json['curriculum'] as Map<String, dynamic>;
      final curriculumId = await _getOrCreate(
        txn,
        'curricula',
        {'code': curriculumJson['code']},
        {'name': curriculumJson['name'], 'description': curriculumJson['description']},
      );

      final subjectJson = json['subject'] as Map<String, dynamic>;
      final subjectId = await _getOrCreate(
        txn,
        'subjects',
        {'curriculum_id': curriculumId, 'code': subjectJson['code']},
        {'name': subjectJson['name'], 'description': subjectJson['description']},
      );

      final gradeJson = json['grade'] as Map<String, dynamic>;
      final gradeId = await _getOrCreate(
        txn,
        'grades',
        {'curriculum_id': curriculumId, 'code': gradeJson['code']},
        {
          'name': gradeJson['name'],
          'sequence_number': gradeJson['level'],
          'phase': gradeJson['phase'],
        },
      );

      for (final termJson in (json['terms'] as List).cast<Map<String, dynamic>>()) {
        final termId = await _getOrCreate(
          txn,
          'terms',
          {'curriculum_id': curriculumId, 'code': termJson['code'] ?? termJson['name']},
          {'name': termJson['name'], 'sequence_number': termJson['sequence_number']},
        );

        for (final topicJson in (termJson['topics'] as List).cast<Map<String, dynamic>>()) {
          final topicId = await _getOrCreate(
            txn,
            'topics',
            {'subject_id': subjectId, 'grade_id': gradeId, 'term_id': termId, 'name': topicJson['name']},
            {'sequence_number': topicJson['sequence_number'], 'description': topicJson['description']},
          );

          for (final obj in (topicJson['learning_objectives'] as List? ?? [])
              .cast<Map<String, dynamic>>()) {
            final existing = await _findObjectiveOrCompetency(
                txn, 'learning_objectives', 'topic_id', topicId, obj['description']);
            if (existing == null) {
              await txn.insert('learning_objectives', {
                'topic_id': topicId,
                'sub_topic_id': null,
                'sequence_number': obj['sequence_number'],
                'description': obj['description'],
              });
            }
          }

          for (final comp in (topicJson['competencies'] as List? ?? []).cast<Map<String, dynamic>>()) {
            final existing = await _findObjectiveOrCompetency(
                txn, 'competencies', 'topic_id', topicId, comp['description']);
            if (existing == null) {
              await txn.insert('competencies', {
                'topic_id': topicId,
                'sub_topic_id': null,
                'sequence_number': comp['sequence_number'],
                'description': comp['description'],
                'category': comp['category'],
              });
            }
          }

          for (final subTopicJson
              in (topicJson['sub_topics'] as List? ?? []).cast<Map<String, dynamic>>()) {
            final subTopicId = await _getOrCreate(
              txn,
              'sub_topics',
              {'topic_id': topicId, 'name': subTopicJson['name']},
              {'sequence_number': subTopicJson['sequence_number'], 'description': subTopicJson['description']},
            );

            for (final obj in (subTopicJson['learning_objectives'] as List? ?? [])
                .cast<Map<String, dynamic>>()) {
              final existing = await _findObjectiveOrCompetency(
                  txn, 'learning_objectives', 'sub_topic_id', subTopicId, obj['description']);
              if (existing == null) {
                await txn.insert('learning_objectives', {
                  'topic_id': null,
                  'sub_topic_id': subTopicId,
                  'sequence_number': obj['sequence_number'],
                  'description': obj['description'],
                });
              }
            }

            for (final comp
                in (subTopicJson['competencies'] as List? ?? []).cast<Map<String, dynamic>>()) {
              final existing = await _findObjectiveOrCompetency(
                  txn, 'competencies', 'sub_topic_id', subTopicId, comp['description']);
              if (existing == null) {
                await txn.insert('competencies', {
                  'topic_id': null,
                  'sub_topic_id': subTopicId,
                  'sequence_number': comp['sequence_number'],
                  'description': comp['description'],
                  'category': comp['category'],
                });
              }
            }
          }
        }
      }
    });
  }

  /// Lists every curriculum that has at least been imported (usually all
  /// bundled ones, since [TemplateRepository.ensureAllSeeded] imports them
  /// on every launch).
  Future<List<Curriculum>> listCurricula() async {
    final db = await database;
    final rows = await db.query('curricula', orderBy: 'name');
    return rows.map(Curriculum.fromMap).toList();
  }

  /// Loads the full syllabus tree for one subject+grade within one
  /// curriculum from local storage. Returns null if that combination hasn't
  /// been imported yet.
  Future<SyllabusTemplate?> getSyllabus({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
  }) async {
    final db = await database;

    final curriculumRows = await db.query('curricula', where: 'code = ?', whereArgs: [curriculumCode]);
    if (curriculumRows.isEmpty) return null;
    final curriculum = Curriculum.fromMap(curriculumRows.first);

    final subjectRows = await db.query(
      'subjects',
      where: 'curriculum_id = ? AND code = ?',
      whereArgs: [curriculum.id, subjectCode],
    );
    final gradeRows = await db.query(
      'grades',
      where: 'curriculum_id = ? AND sequence_number = ?',
      whereArgs: [curriculum.id, gradeLevel],
    );
    if (subjectRows.isEmpty || gradeRows.isEmpty) return null;

    final subject = Subject.fromMap(subjectRows.first);
    final grade = Grade.fromMap(gradeRows.first);

    final topicRows = await db.rawQuery('''
      SELECT topics.*, terms.name AS term_name, terms.sequence_number AS term_sequence_number,
             terms.id AS term_id
      FROM topics
      JOIN terms ON terms.id = topics.term_id
      WHERE topics.subject_id = ? AND topics.grade_id = ?
      ORDER BY terms.sequence_number, topics.sequence_number
    ''', [subject.id, grade.id]);

    if (topicRows.isEmpty) {
      return SyllabusTemplate(curriculum: curriculum, subject: subject, grade: grade, terms: const []);
    }

    final termsById = <int, List<Topic>>{};
    final termMeta = <int, Map<String, Object?>>{};

    for (final row in topicRows) {
      final termId = row['term_id'] as int;
      termMeta[termId] = {'name': row['term_name'], 'sequence_number': row['term_sequence_number']};

      final topicId = row['id'] as int;
      final subTopics = await _loadSubTopics(db, topicId);
      final objectives = await _loadObjectives(db, topicId: topicId);
      final competencies = await _loadCompetencies(db, topicId: topicId);

      termsById.putIfAbsent(termId, () => []).add(Topic(
            id: topicId,
            sequenceNumber: row['sequence_number'] as int,
            name: row['name'] as String,
            description: row['description'] as String?,
            subTopics: subTopics,
            objectives: objectives,
            competencies: competencies,
          ));
    }

    final terms = termsById.entries.map((entry) {
      final meta = termMeta[entry.key]!;
      return Term(
        id: entry.key,
        sequenceNumber: meta['sequence_number'] as int,
        name: meta['name'] as String,
        topics: entry.value,
      );
    }).toList()
      ..sort((a, b) => a.sequenceNumber.compareTo(b.sequenceNumber));

    return SyllabusTemplate(curriculum: curriculum, subject: subject, grade: grade, terms: terms);
  }

  /// Records the topic a teacher last concluded for one subject+grade within
  /// one curriculum. Overwrites any previous mark for that exact
  /// curriculum+subject+grade combination — a mark made under one curriculum
  /// never collides with the same subject+grade under the other, since
  /// subject_id/grade_id are themselves curriculum-scoped rows. Stored
  /// purely on-device.
  Future<void> setLastConcludedTopic({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required int topicId,
  }) async {
    final db = await database;
    final curriculumId = await _requireId(db, 'curricula', {'code': curriculumCode});
    final subjectId = await _requireId(db, 'subjects', {'curriculum_id': curriculumId, 'code': subjectCode});
    final gradeId =
        await _requireId(db, 'grades', {'curriculum_id': curriculumId, 'sequence_number': gradeLevel});
    await db.insert(
      'topic_progress',
      {
        'subject_id': subjectId,
        'grade_id': gradeId,
        'last_concluded_topic_id': topicId,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns the id of the topic last marked concluded for a subject+grade
  /// within one curriculum, or null if nothing has been marked yet.
  Future<int?> getLastConcludedTopicId({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
  }) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT topic_progress.last_concluded_topic_id AS topic_id
      FROM topic_progress
      JOIN subjects ON subjects.id = topic_progress.subject_id
      JOIN grades ON grades.id = topic_progress.grade_id
      JOIN curricula ON curricula.id = subjects.curriculum_id
      WHERE curricula.code = ? AND subjects.code = ? AND grades.sequence_number = ?
      LIMIT 1
    ''', [curriculumCode, subjectCode, gradeLevel]);
    return rows.isEmpty ? null : rows.first['topic_id'] as int;
  }

  Future<int> _requireId(DatabaseExecutor db, String table, Map<String, Object?> match) async {
    final where = match.keys.map((k) => '$k = ?').join(' AND ');
    final rows = await db.query(table, columns: ['id'], where: where, whereArgs: match.values.toList(), limit: 1);
    if (rows.isEmpty) {
      throw StateError('No row in $table matching $match');
    }
    return rows.first['id'] as int;
  }

  Future<List<SubTopic>> _loadSubTopics(Database db, int topicId) async {
    final rows = await db.query(
      'sub_topics',
      where: 'topic_id = ?',
      whereArgs: [topicId],
      orderBy: 'sequence_number',
    );
    final result = <SubTopic>[];
    for (final row in rows) {
      final subTopicId = row['id'] as int;
      result.add(SubTopic(
        id: subTopicId,
        sequenceNumber: row['sequence_number'] as int,
        name: row['name'] as String,
        description: row['description'] as String?,
        objectives: await _loadObjectives(db, subTopicId: subTopicId),
        competencies: await _loadCompetencies(db, subTopicId: subTopicId),
      ));
    }
    return result;
  }

  Future<List<LearningObjective>> _loadObjectives(Database db, {int? topicId, int? subTopicId}) async {
    final column = subTopicId != null ? 'sub_topic_id' : 'topic_id';
    final id = subTopicId ?? topicId;
    final rows = await db.query(
      'learning_objectives',
      where: '$column = ?',
      whereArgs: [id],
      orderBy: 'sequence_number',
    );
    return rows.map(LearningObjective.fromMap).toList();
  }

  Future<List<Competency>> _loadCompetencies(Database db, {int? topicId, int? subTopicId}) async {
    final column = subTopicId != null ? 'sub_topic_id' : 'topic_id';
    final id = subTopicId ?? topicId;
    final rows = await db.query(
      'competencies',
      where: '$column = ?',
      whereArgs: [id],
      orderBy: 'sequence_number',
    );
    return rows.map(Competency.fromMap).toList();
  }
}
