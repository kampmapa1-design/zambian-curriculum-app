import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/syllabus_models.dart';

/// Local SQLite storage for syllabus templates. Schema mirrors the desktop
/// zambian-curriculum-db project: subjects -> grades -> terms -> topics ->
/// sub_topics -> learning_objectives / competencies. Everything lives on
/// device, so lookups work fully offline.
class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

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
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE subjects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            code TEXT NOT NULL UNIQUE,
            description TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE grades (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            level INTEGER NOT NULL UNIQUE,
            phase TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE terms (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            sequence_number INTEGER NOT NULL UNIQUE
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
      },
    );
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
  /// creating duplicate rows.
  Future<void> importTemplate(Map<String, dynamic> json) async {
    final db = await database;
    await db.transaction((txn) async {
      final subjectJson = json['subject'] as Map<String, dynamic>;
      final subjectId = await _getOrCreate(
        txn,
        'subjects',
        {'code': subjectJson['code']},
        {'name': subjectJson['name'], 'description': subjectJson['description']},
      );

      final gradeJson = json['grade'] as Map<String, dynamic>;
      final gradeId = await _getOrCreate(
        txn,
        'grades',
        {'name': gradeJson['name']},
        {'level': gradeJson['level'], 'phase': gradeJson['phase']},
      );

      for (final termJson in (json['terms'] as List).cast<Map<String, dynamic>>()) {
        final termId = await _getOrCreate(
          txn,
          'terms',
          {'name': termJson['name']},
          {'sequence_number': termJson['sequence_number']},
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

  /// Loads the full syllabus tree for one subject+grade from local storage.
  /// Returns null if that combination hasn't been imported yet.
  Future<SyllabusTemplate?> getSyllabus({
    required String subjectCode,
    required int gradeLevel,
  }) async {
    final db = await database;

    final subjectRows = await db.query('subjects', where: 'code = ?', whereArgs: [subjectCode]);
    final gradeRows = await db.query('grades', where: 'level = ?', whereArgs: [gradeLevel]);
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

    if (topicRows.isEmpty) return SyllabusTemplate(subject: subject, grade: grade, terms: const []);

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

    return SyllabusTemplate(subject: subject, grade: grade, terms: terms);
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
