// Real SQLite coverage (2026-09-15) for ClassProgressRepository — see
// support/sqlite_test_setup.dart for how `flutter test` gets a real,
// disposable SQLite database without any platform channels. Fixtures come
// from support/syllabus_fixture.dart, imported through the same
// DatabaseHelper.importTemplate path the app itself uses.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/lesson_history_entry.dart';
import 'package:zambian_curriculum_app/services/class_progress_repository.dart';
import 'package:zambian_curriculum_app/services/database_helper.dart';
import 'package:zambian_curriculum_app/services/lesson_history_repository.dart';

import 'support/sqlite_test_setup.dart';
import 'support/syllabus_fixture.dart';

void main() {
  late ClassProgressRepository repo;
  late LessonHistoryRepository lessonHistory;
  late SeededSyllabus syllabus;

  setUp(() async {
    await setUpTestDatabase();
    repo = ClassProgressRepository(databaseHelper: DatabaseHelper.instance);
    lessonHistory = LessonHistoryRepository(databaseHelper: DatabaseHelper.instance);
    syllabus = await seedMinimalSyllabus(DatabaseHelper.instance);
  });

  test('no progress recorded yet returns null', () async {
    final progress = await repo.getProgress(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
    );
    expect(progress, isNull);
  });

  test('markConcluded records a sub-topic-level cursor, readable back exactly', () async {
    await repo.markConcluded(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub1Id,
    );
    final progress = await repo.getProgress(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
    );
    expect(progress, (topicId: syllabus.topicAId, subTopicId: syllabus.topicASub1Id));
  });

  test('markConcluded with no sub-topic means the WHOLE topic — subTopicId stays null', () async {
    await repo.markConcluded(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
      topicId: syllabus.topicAId,
    );
    final progress = await repo.getProgress(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
    );
    expect(progress!.topicId, syllabus.topicAId);
    expect(progress.subTopicId, isNull);
  });

  test('two class labels for the same subject+grade never share a cursor', () async {
    await repo.markConcluded(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub1Id,
    );
    await repo.markConcluded(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10B',
      topicId: syllabus.topicBId,
    );

    final progressA = await repo.getProgress(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
    );
    final progressB = await repo.getProgress(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10B',
    );
    expect(progressA, (topicId: syllabus.topicAId, subTopicId: syllabus.topicASub1Id));
    expect(progressB, (topicId: syllabus.topicBId, subTopicId: null));
  });

  test('marking concluded again for the same class label overwrites, not duplicates', () async {
    await repo.markConcluded(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub1Id,
    );
    await repo.markConcluded(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub2Id,
    );
    final progress = await repo.getProgress(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
    );
    expect(progress, (topicId: syllabus.topicAId, subTopicId: syllabus.topicASub2Id));

    final labels = await repo.listClassLabels(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
    );
    expect(labels, ['Grade 10A']);
  });

  test('listClassLabels lists every previously used label, most recently updated first', () async {
    await repo.markConcluded(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
      topicId: syllabus.topicAId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.markConcluded(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10B',
      topicId: syllabus.topicAId,
    );

    final labels = await repo.listClassLabels(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
    );
    expect(labels, ['Grade 10B', 'Grade 10A']);
  });

  test('markConcluded also logs a completed lesson history entry — one action, two records', () async {
    await repo.markConcluded(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      classLabel: 'Grade 10A',
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub1Id,
    );
    final history = await lessonHistory.query(
      from: DateTime.now().subtract(const Duration(days: 1)),
      to: DateTime.now().add(const Duration(days: 1)),
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
    );
    expect(history, hasLength(1));
    expect(history.single.topicId, syllabus.topicAId);
    expect(history.single.subTopicId, syllabus.topicASub1Id);
    expect(history.single.status, LessonHistoryStatus.completed);
  });
}
