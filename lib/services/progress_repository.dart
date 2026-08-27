import 'database_helper.dart';
import 'lesson_history_repository.dart';

/// Persists which topic a teacher last concluded, per curriculum+subject+
/// grade, in local SQLite storage. No network access — reads and writes
/// stay on-device.
class ProgressRepository {
  ProgressRepository({DatabaseHelper? databaseHelper, LessonHistoryRepository? lessonHistoryRepository})
      : _db = databaseHelper ?? DatabaseHelper.instance,
        _lessonHistory = lessonHistoryRepository ?? LessonHistoryRepository(databaseHelper: databaseHelper);

  final DatabaseHelper _db;
  final LessonHistoryRepository _lessonHistory;

  Future<int?> getLastConcludedTopicId({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
  }) =>
      _db.getLastConcludedTopicId(
        curriculumCode: curriculumCode,
        subjectCode: subjectCode,
        gradeLevel: gradeLevel,
      );

  /// Marks [topicId] as the last concluded topic (existing "resume where I
  /// left off" cursor, unchanged) and, additionally, logs it as a
  /// 'completed' entry in the lesson history that "Generate Record of Work"
  /// pulls from — this is the app's one existing "mark this topic
  /// taught/concluded" action, reused rather than duplicated.
  Future<void> markTopicConcluded({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required int topicId,
  }) async {
    await _db.setLastConcludedTopic(
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
      topicId: topicId,
    );
    await _lessonHistory.logCompleted(
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
      topicId: topicId,
    );
  }
}
