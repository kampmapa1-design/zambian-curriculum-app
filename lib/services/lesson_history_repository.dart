import '../models/lesson_history_entry.dart';
import 'database_helper.dart';

/// Auto-captured log of every lesson plan/scheme generated and every topic
/// marked taught/concluded — see [LessonHistoryEntry]. Purely on-device,
/// feeds "Generate Record of Work" (see `RecordOfWorkRepository`).
class LessonHistoryRepository {
  LessonHistoryRepository({DatabaseHelper? databaseHelper}) : _db = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _db;

  Future<void> logLessonPlanGenerated({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required int topicId,
    int? subTopicId,
  }) =>
      _db.logLessonHistory(
        curriculumCode: curriculumCode,
        subjectCode: subjectCode,
        gradeLevel: gradeLevel,
        topicId: topicId,
        subTopicId: subTopicId,
        source: LessonHistorySource.lessonPlan,
        status: LessonHistoryStatus.generated,
        date: DateTime.now(),
      );

  Future<void> logSchemeGenerated({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required int topicId,
    int? subTopicId,
  }) =>
      _db.logLessonHistory(
        curriculumCode: curriculumCode,
        subjectCode: subjectCode,
        gradeLevel: gradeLevel,
        topicId: topicId,
        subTopicId: subTopicId,
        source: LessonHistorySource.schemeOfWork,
        status: LessonHistoryStatus.generated,
        date: DateTime.now(),
      );

  Future<void> logCompleted({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required int topicId,
    int? subTopicId,
    LessonHistorySource source = LessonHistorySource.schemeOfWork,
  }) =>
      _db.logLessonHistory(
        curriculumCode: curriculumCode,
        subjectCode: subjectCode,
        gradeLevel: gradeLevel,
        topicId: topicId,
        subTopicId: subTopicId,
        source: source,
        status: LessonHistoryStatus.completed,
        date: DateTime.now(),
      );

  Future<List<LessonHistoryEntry>> query({
    required DateTime from,
    required DateTime to,
    String? curriculumCode,
    String? subjectCode,
    int? gradeLevel,
    LessonHistoryStatus? status,
  }) =>
      _db.queryLessonHistory(
        from: from,
        to: to,
        curriculumCode: curriculumCode,
        subjectCode: subjectCode,
        gradeLevel: gradeLevel,
        status: status,
      );
}
