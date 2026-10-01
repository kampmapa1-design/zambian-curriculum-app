/// One structural piece of an embedded lesson plan's real content, indexed
/// for full-text search (Embedded Content Search, Stage 1, 2026-09-22).
///
/// [groupKey] identifies the CANDIDATE DOCUMENT this segment belongs to —
/// not one individual 40-minute lesson, but everything sharing the same
/// (curriculum, subject, grade, topic name, sub-topic name). A real topic
/// like "1.1 INTRODUCTION TO HISTORY" is usually taught across many
/// numbered lessons (`sequenceLabel` "Lesson 1 of 20", "Lesson 2 of 20", ...)
/// that all share one sub-topic — pooling them into one group is what makes
/// [segmentOrder] meaningful as a real "paragraph boundary" sequence across
/// the sub-topic's whole real content, and it's the right granularity for
/// "Fine Tune" (Stage 6-9): a scheme entry is one topic/sub-topic, not one
/// individual lesson.
enum EmbeddedContentSegmentKind {
  /// The topic or sub-topic name itself, as a heading candidate — see
  /// MatchConfidenceScorer's "heading/subheading match" criterion.
  heading,

  /// Real body content (major learning point, lesson goal, rationale,
  /// prior knowledge, objectives, or one progression stage's teacher/
  /// learner content) — see MatchConfidenceScorer's density/span criteria.
  body,
}

class EmbeddedContentSegment {
  final String groupKey;
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final String topicName;
  final String? subtopicName;
  final EmbeddedContentSegmentKind kind;

  /// The progression stage this segment came from (e.g. "Introduction",
  /// "Development"), only set for a body segment derived from
  /// [EmbeddedProgressionRow] — null for every other segment.
  final String? stage;

  /// Position of this segment within its group, in source order — the
  /// "paragraph boundaries" Stage 1 asks for, used by the confidence
  /// scorer to compute a contiguous span.
  final int segmentOrder;

  /// The searchable text of this specific segment.
  final String text;

  const EmbeddedContentSegment({
    required this.groupKey,
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.topicName,
    this.subtopicName,
    required this.kind,
    this.stage,
    required this.segmentOrder,
    required this.text,
  });

  /// What a candidate document is actually "about", for display and for
  /// the heading-match criterion — the sub-topic when there is one
  /// (the narrower, more specific real heading), else the topic itself.
  String get heading => (subtopicName != null && subtopicName!.trim().isNotEmpty) ? subtopicName! : topicName;

  Map<String, Object?> toMap() => {
        'group_key': groupKey,
        'curriculum_code': curriculumCode,
        'subject_code': subjectCode,
        'grade_level': gradeLevel,
        'topic_name': topicName,
        'subtopic_name': subtopicName,
        'kind': kind.name,
        'stage': stage,
        'segment_order': segmentOrder,
        'text': text,
      };

  factory EmbeddedContentSegment.fromMap(Map<String, Object?> map) => EmbeddedContentSegment(
        groupKey: map['group_key'] as String,
        curriculumCode: map['curriculum_code'] as String,
        subjectCode: map['subject_code'] as String,
        gradeLevel: map['grade_level'] as int,
        topicName: map['topic_name'] as String,
        subtopicName: map['subtopic_name'] as String?,
        kind: EmbeddedContentSegmentKind.values.byName(map['kind'] as String),
        stage: map['stage'] as String?,
        segmentOrder: map['segment_order'] as int,
        text: map['text'] as String,
      );
}
