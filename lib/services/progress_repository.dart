import 'database_helper.dart';

/// Persists which topic a teacher last concluded, per curriculum+subject+
/// grade, in local SQLite storage. No network access — reads and writes
/// stay on-device.
class ProgressRepository {
  ProgressRepository({DatabaseHelper? databaseHelper}) : _db = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _db;

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

  Future<void> markTopicConcluded({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required int topicId,
  }) =>
      _db.setLastConcludedTopic(
        curriculumCode: curriculumCode,
        subjectCode: subjectCode,
        gradeLevel: gradeLevel,
        topicId: topicId,
      );
}
