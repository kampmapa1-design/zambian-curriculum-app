import 'database_helper.dart';
import 'lesson_history_repository.dart';

/// One resolved "where did this class reach" answer — the topic (and,
/// optionally, the exact sub-topic within it) a class last concluded.
/// [subTopicId] null means the WHOLE topic, every one of its sub-topics
/// included, was concluded — not just its first sub-topic.
typedef ClassProgress = ({int topicId, int? subTopicId});

/// Persists which topic/sub-topic a NAMED CLASS last concluded, per
/// curriculum+subject+grade+class label, in local SQLite storage. No
/// network access — reads and writes stay on-device.
///
/// **Why a class label, not just subject+grade** (replaces the old
/// `ProgressRepository`/`topic_progress`, which tracked exactly one cursor
/// per subject+grade with no further distinction): a teacher can run two
/// sections of the same subject+grade at genuinely different paces (e.g.
/// "Grade 10A" ahead of "Grade 10B"), and — the case that surfaced this
/// design — might generate a one-off scheme for a colleague who can't
/// print from their own device. Neither situation should silently
/// overwrite the teacher's own regular class's real progress record. A
/// class label is free text the teacher types (same reasoning as
/// AI-Assisted Marking's free-text subject/level entry — see
/// MarkingSchemeBuilderScreen's doc comment): "Grade 10A", "my class", or
/// "printing for Mr. Banda" all work, and a one-off/colleague label simply
/// starts with no history rather than touching anyone else's.
///
/// This is also why Scheme of Work generation always asks — never
/// silently trusts a stored cursor — before generating: see
/// ClassResumePickerScreen. This repository supplies the *default*
/// suggestion; the teacher's own answer each time is what actually governs.
class ClassProgressRepository {
  ClassProgressRepository({DatabaseHelper? databaseHelper, LessonHistoryRepository? lessonHistoryRepository})
      : _db = databaseHelper ?? DatabaseHelper.instance,
        _lessonHistory = lessonHistoryRepository ?? LessonHistoryRepository(databaseHelper: databaseHelper);

  final DatabaseHelper _db;
  final LessonHistoryRepository _lessonHistory;

  Future<ClassProgress?> getProgress({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required String classLabel,
  }) async {
    final result = await _db.getClassProgress(
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
      classLabel: classLabel,
    );
    if (result == null) return null;
    return (topicId: result.$1, subTopicId: result.$2);
  }

  /// Every class label previously used for this subject+grade, most
  /// recently updated first — feeds ClassResumePickerScreen's autocomplete.
  Future<List<String>> listClassLabels({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
  }) =>
      _db.listClassLabels(curriculumCode: curriculumCode, subjectCode: subjectCode, gradeLevel: gradeLevel);

  /// Marks [topicId] (and, when given, the specific [subTopicId] within it)
  /// as the last concluded point for [classLabel] — the "resume where this
  /// class left off" cursor — and, additionally, logs it as a 'completed'
  /// entry in the lesson history that "Generate Record of Work" pulls from.
  /// This is the app's one "mark this topic/sub-topic taught/concluded"
  /// action for a named class, reused rather than duplicated.
  Future<void> markConcluded({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required String classLabel,
    required int topicId,
    int? subTopicId,
  }) async {
    await _db.setClassProgress(
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
      classLabel: classLabel,
      topicId: topicId,
      subTopicId: subTopicId,
    );
    await _lessonHistory.logCompleted(
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
      topicId: topicId,
      subTopicId: subTopicId,
    );
  }
}
