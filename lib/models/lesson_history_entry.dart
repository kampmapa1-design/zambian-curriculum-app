/// One row in the lesson history log — an automatic, append-only record of
/// every topic/sub-topic a lesson plan or scheme of work was generated for,
/// and (separately) every one actually marked taught/concluded. Feeds
/// "Generate Record of Work": rather than a teacher re-entering what they
/// covered, the app already knows from its own generation/completion
/// history. Stored on-device only (see `DatabaseHelper`'s `lesson_history`
/// table) — this never leaves the device.
class LessonHistoryEntry {
  final int id;
  final String curriculumCode;
  final String curriculumName;
  final String subjectCode;
  final String subjectName;
  final int gradeLevel;
  final String gradeName;
  final int topicId;
  final String topicName;
  final int? subTopicId;
  final String? subTopicName;

  /// Which "Generate ..." flow produced this entry.
  final LessonHistorySource source;

  /// 'generated' the moment a document was produced; upgraded to
  /// 'completed' when the teacher explicitly marks the topic
  /// taught/concluded — never downgraded back once completed.
  final LessonHistoryStatus status;

  final DateTime date;

  const LessonHistoryEntry({
    required this.id,
    required this.curriculumCode,
    required this.curriculumName,
    required this.subjectCode,
    required this.subjectName,
    required this.gradeLevel,
    required this.gradeName,
    required this.topicId,
    required this.topicName,
    this.subTopicId,
    this.subTopicName,
    required this.source,
    required this.status,
    required this.date,
  });

  /// "Topic — Sub-topic", or just "Topic" when there's no sub-topic.
  String get topicLabel => subTopicName == null ? topicName : '$topicName — $subTopicName';
}

enum LessonHistorySource { lessonPlan, schemeOfWork }

extension LessonHistorySourceDb on LessonHistorySource {
  String get dbValue => switch (this) {
        LessonHistorySource.lessonPlan => 'lesson_plan',
        LessonHistorySource.schemeOfWork => 'scheme_of_work',
      };

  static LessonHistorySource fromDb(String value) => switch (value) {
        'lesson_plan' => LessonHistorySource.lessonPlan,
        'scheme_of_work' => LessonHistorySource.schemeOfWork,
        _ => throw ArgumentError('Unknown lesson history source: $value'),
      };
}

enum LessonHistoryStatus { generated, completed }

extension LessonHistoryStatusDb on LessonHistoryStatus {
  String get dbValue => switch (this) {
        LessonHistoryStatus.generated => 'generated',
        LessonHistoryStatus.completed => 'completed',
      };

  static LessonHistoryStatus fromDb(String value) => switch (value) {
        'generated' => LessonHistoryStatus.generated,
        'completed' => LessonHistoryStatus.completed,
        _ => throw ArgumentError('Unknown lesson history status: $value'),
      };
}
