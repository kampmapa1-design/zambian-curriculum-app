/// One real, teacher-authored lesson plan sourced verbatim (sanitized —
/// personal identifiers stripped) from the user's own Drive documents,
/// rather than generated. See [EmbeddedLessonPlanSet] for the file this
/// belongs to, and `EmbeddedLessonPlanRepository` for how these are matched
/// against a topic a teacher is browsing.
class EmbeddedLessonPlan {
  final String topicName;
  final String? subtopicName;

  /// Set only when one asset file spans multiple grades/forms (e.g.
  /// Religious Education Grade 10-11 in one file) and a specific lesson
  /// needs to say which — null means "every grade in the parent
  /// [EmbeddedLessonPlanSet.gradeLevels]".
  final int? gradeLevel;

  /// e.g. "Lesson 3 of 17" when the source numbers multiple lessons on the
  /// same topic — real CBC/OBC practice, one topic taught across several
  /// separate 40-minute lessons.
  final String? sequenceLabel;

  final String? majorLearningPoint;
  final String? lessonGoal;
  final String? duration;
  final String? references;
  final String? tlm;
  final String? rationale;
  final List<String> objectives;
  final String? priorKnowledge;
  final List<EmbeddedProgressionRow> progression;

  const EmbeddedLessonPlan({
    required this.topicName,
    this.subtopicName,
    this.gradeLevel,
    this.sequenceLabel,
    this.majorLearningPoint,
    this.lessonGoal,
    this.duration,
    this.references,
    this.tlm,
    this.rationale,
    this.objectives = const [],
    this.priorKnowledge,
    this.progression = const [],
  });

  factory EmbeddedLessonPlan.fromJson(Map<String, dynamic> json) => EmbeddedLessonPlan(
        topicName: json['topic_name'] as String,
        subtopicName: json['subtopic_name'] as String?,
        gradeLevel: json['grade_level'] as int?,
        sequenceLabel: json['sequence_label'] as String?,
        majorLearningPoint: json['majorLearningPoint'] as String?,
        lessonGoal: json['lessonGoal'] as String?,
        duration: json['duration'] as String?,
        references: json['references'] as String?,
        tlm: json['tlm'] as String?,
        rationale: json['rationale'] as String?,
        objectives: (json['objectives'] as List?)?.cast<String>() ?? const [],
        priorKnowledge: json['priorKnowledge'] as String?,
        progression: (json['progression'] as List?)
                ?.cast<Map<String, dynamic>>()
                .map(EmbeddedProgressionRow.fromJson)
                .toList() ??
            const [],
      );
}

class EmbeddedProgressionRow {
  final String stage;
  final String? teacherRole;
  final String? learnersRole;

  const EmbeddedProgressionRow({required this.stage, this.teacherRole, this.learnersRole});

  factory EmbeddedProgressionRow.fromJson(Map<String, dynamic> json) => EmbeddedProgressionRow(
        stage: json['stage'] as String,
        teacherRole: json['teacherRole'] as String?,
        learnersRole: json['learnersRole'] as String?,
      );
}

/// One bundled asset file (`assets/lesson_plans/*.json`) — every embedded
/// lesson plan for one subject (spanning one or more grades/forms) within
/// one curriculum.
class EmbeddedLessonPlanSet {
  final String source;
  final String curriculumCode;
  final String subjectCode;
  final List<int> gradeLevels;
  final List<EmbeddedLessonPlan> lessonPlans;

  const EmbeddedLessonPlanSet({
    required this.source,
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevels,
    required this.lessonPlans,
  });

  factory EmbeddedLessonPlanSet.fromJson(Map<String, dynamic> json) => EmbeddedLessonPlanSet(
        source: json['_source'] as String,
        curriculumCode: json['curriculum_code'] as String,
        subjectCode: json['subject_code'] as String,
        gradeLevels: (json['grade_levels'] as List).cast<int>(),
        lessonPlans: (json['lesson_plans'] as List)
            .cast<Map<String, dynamic>>()
            .map(EmbeddedLessonPlan.fromJson)
            .toList(),
      );
}
