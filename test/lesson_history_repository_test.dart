// Real SQLite coverage (2026-09-15) for LessonHistoryRepository — see
// support/sqlite_test_setup.dart for the `flutter test` SQLite mechanism.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/lesson_history_entry.dart';
import 'package:zambian_curriculum_app/services/database_helper.dart';
import 'package:zambian_curriculum_app/services/lesson_history_repository.dart';

import 'support/sqlite_test_setup.dart';
import 'support/syllabus_fixture.dart';

void main() {
  late LessonHistoryRepository repo;
  late SeededSyllabus syllabus;

  DateTime from() => DateTime.now().subtract(const Duration(days: 1));
  DateTime to() => DateTime.now().add(const Duration(days: 1));

  setUp(() async {
    await setUpTestDatabase();
    repo = LessonHistoryRepository(databaseHelper: DatabaseHelper.instance);
    syllabus = await seedMinimalSyllabus(DatabaseHelper.instance);
  });

  test('logLessonPlanGenerated records a generated entry sourced from a lesson plan', () async {
    await repo.logLessonPlanGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub1Id,
    );
    final results = await repo.query(from: from(), to: to());
    expect(results, hasLength(1));
    expect(results.single.source, LessonHistorySource.lessonPlan);
    expect(results.single.status, LessonHistoryStatus.generated);
  });

  test('logSchemeGenerated records a generated entry sourced from a scheme of work', () async {
    await repo.logSchemeGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
    );
    final results = await repo.query(from: from(), to: to());
    expect(results.single.source, LessonHistorySource.schemeOfWork);
    expect(results.single.status, LessonHistoryStatus.generated);
    expect(results.single.subTopicId, isNull);
  });

  test('logCompleted defaults to scheme-of-work source but accepts an override', () async {
    await repo.logCompleted(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
      source: LessonHistorySource.lessonPlan,
    );
    final results = await repo.query(from: from(), to: to());
    expect(results.single.source, LessonHistorySource.lessonPlan);
    expect(results.single.status, LessonHistoryStatus.completed);
  });

  test('re-logging the same topic/sub-topic/source upserts rather than duplicating', () async {
    await repo.logLessonPlanGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub1Id,
    );
    await repo.logLessonPlanGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub1Id,
    );
    final results = await repo.query(from: from(), to: to());
    expect(results, hasLength(1));
  });

  test('a topic-level entry (no sub-topic) and a sub-topic entry under the same topic are distinct rows', () async {
    await repo.logSchemeGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
    );
    await repo.logSchemeGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub1Id,
    );
    final results = await repo.query(from: from(), to: to());
    expect(results, hasLength(2));
  });

  test('a completed entry never regresses back to generated', () async {
    await repo.logCompleted(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
      source: LessonHistorySource.lessonPlan,
    );
    // A lesson plan re-opened/re-exported for the same topic afterwards —
    // must not downgrade the already-completed record.
    await repo.logLessonPlanGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
    );
    final results = await repo.query(from: from(), to: to());
    expect(results, hasLength(1));
    expect(results.single.status, LessonHistoryStatus.completed);
  });

  test('different sources for the same topic are tracked independently', () async {
    await repo.logLessonPlanGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
    );
    await repo.logSchemeGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
    );
    final results = await repo.query(from: from(), to: to());
    expect(results, hasLength(2));
    expect(results.map((e) => e.source).toSet(), {LessonHistorySource.lessonPlan, LessonHistorySource.schemeOfWork});
  });

  test('query narrows by date range, excluding entries outside it', () async {
    await repo.logSchemeGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
    );
    final results = await repo.query(
      from: DateTime.now().add(const Duration(days: 10)),
      to: DateTime.now().add(const Duration(days: 20)),
    );
    expect(results, isEmpty);
  });

  test('query narrows by status', () async {
    await repo.logSchemeGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
    );
    await repo.logCompleted(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicBId,
    );
    final generatedOnly = await repo.query(from: from(), to: to(), status: LessonHistoryStatus.generated);
    expect(generatedOnly, hasLength(1));
    expect(generatedOnly.single.topicId, syllabus.topicAId);
  });

  test('query narrows by curriculum/subject/grade, excluding another subject entirely', () async {
    final otherSyllabus = await seedMinimalSyllabus(
      DatabaseHelper.instance,
      subjectCode: 'OTHER_SUBJ',
    );
    await repo.logSchemeGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
    );
    await repo.logSchemeGenerated(
      curriculumCode: otherSyllabus.curriculumCode,
      subjectCode: otherSyllabus.subjectCode,
      gradeLevel: otherSyllabus.gradeLevel,
      topicId: otherSyllabus.topicAId,
    );
    final results = await repo.query(from: from(), to: to(), subjectCode: syllabus.subjectCode);
    expect(results, hasLength(1));
    expect(results.single.subjectCode, syllabus.subjectCode);
  });

  test('topicLabel reads "Topic — Sub-topic" when a sub-topic is present, else just the topic', () async {
    await repo.logSchemeGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicAId,
      subTopicId: syllabus.topicASub1Id,
    );
    await repo.logSchemeGenerated(
      curriculumCode: syllabus.curriculumCode,
      subjectCode: syllabus.subjectCode,
      gradeLevel: syllabus.gradeLevel,
      topicId: syllabus.topicBId,
    );
    final results = await repo.query(from: from(), to: to());
    final withSub = results.firstWhere((e) => e.subTopicId != null);
    final withoutSub = results.firstWhere((e) => e.subTopicId == null);
    expect(withSub.topicLabel, 'Topic A — A.1');
    expect(withoutSub.topicLabel, 'Topic B');
  });
}
