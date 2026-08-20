import 'lesson_plan.dart';

/// A saved mid-lesson checkpoint (Stage 6: "Resume Lesson"). Identifies
/// exactly which lesson — curriculum + subject + grade + topic + sub-topic
/// — and which Lesson Progression stage the teacher reached, plus the full
/// draft, so resuming restores everything typed in, not just the stage.
/// One checkpoint per lesson (see [lessonKey]) — saving again overwrites
/// the previous checkpoint for that same lesson.
class LessonCheckpoint {
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final int topicId;
  final int? subTopicId;
  final String templateId;
  final int reachedStageIndex;
  final LessonPlanDraft draft;
  final DateTime savedAt;

  const LessonCheckpoint({
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.topicId,
    required this.subTopicId,
    required this.templateId,
    required this.reachedStageIndex,
    required this.draft,
    required this.savedAt,
  });

  String get lessonKey => keyFor(
        curriculumCode: curriculumCode,
        subjectCode: subjectCode,
        gradeLevel: gradeLevel,
        topicId: topicId,
        subTopicId: subTopicId,
      );

  static String keyFor({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required int topicId,
    required int? subTopicId,
  }) =>
      '$curriculumCode|$subjectCode|$gradeLevel|$topicId|${subTopicId ?? ""}';

  Map<String, dynamic> toJson() => {
        'curriculumCode': curriculumCode,
        'subjectCode': subjectCode,
        'gradeLevel': gradeLevel,
        'topicId': topicId,
        'subTopicId': subTopicId,
        'templateId': templateId,
        'reachedStageIndex': reachedStageIndex,
        'draft': draft.toJson(),
        'savedAt': savedAt.toIso8601String(),
      };

  factory LessonCheckpoint.fromJson(Map<String, dynamic> json) => LessonCheckpoint(
        curriculumCode: json['curriculumCode'] as String,
        subjectCode: json['subjectCode'] as String,
        gradeLevel: json['gradeLevel'] as int,
        topicId: json['topicId'] as int,
        subTopicId: json['subTopicId'] as int?,
        templateId: json['templateId'] as String,
        reachedStageIndex: json['reachedStageIndex'] as int,
        draft: LessonPlanDraft.fromJson(json['draft'] as Map<String, dynamic>),
        savedAt: DateTime.parse(json['savedAt'] as String),
      );
}
