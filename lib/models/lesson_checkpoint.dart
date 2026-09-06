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

  /// Whether the lesson this checkpoint belongs to was started as a
  /// "one off" lesson plan (2026-09-06 — see generate_lesson_plan_flow
  /// .dart's own "One off lesson plan?" question) — carried through so
  /// resuming a paused one-off lesson keeps behaving like one (no class
  /// question re-asked, no lesson-history entry logged on export) rather
  /// than silently reverting to normal, class-tracked behaviour just
  /// because it was paused partway through. Defaults false for checkpoints
  /// saved before this field existed.
  final bool isOneOff;

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
    this.isOneOff = false,
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
        'isOneOff': isOneOff,
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
        isOneOff: json['isOneOff'] as bool? ?? false,
      );
}
