import '../models/embedded_content_segment.dart';
import '../models/embedded_lesson_plan.dart';

/// Turns every bundled [EmbeddedLessonPlanSet] into a flat list of
/// [EmbeddedContentSegment]s — the real body content of every embedded
/// lesson plan, structured enough (heading segments, ordered body segments)
/// to support [MatchConfidenceScorer]. Pure, no I/O — the actual storage
/// (SQLite/FTS5) is [EmbeddedContentIndexService]'s job; keeping this
/// separate means the indexing logic itself is directly unit-testable
/// without a database.
///
/// Entirely generic across whatever subjects/grades are bundled: nothing
/// here names a specific subject, curriculum, or topic — every field comes
/// straight from each set's own `curriculum_code`/`subject_code`/
/// `grade_levels` and each plan's own `topic_name`/`subtopic_name`, so a
/// newly bundled subject's content is indexed with no code change.
String normalizeHeadingKey(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

/// The candidate-document identity a group of segments belongs to — see
/// [EmbeddedContentSegment]'s own doc comment on why this is
/// (curriculum, subject, grade, topic, sub-topic) rather than one lesson.
String embeddedContentGroupKey({
  required String curriculumCode,
  required String subjectCode,
  required int gradeLevel,
  required String topicName,
  String? subtopicName,
}) =>
    '${curriculumCode.toUpperCase()}|${subjectCode.toUpperCase()}|$gradeLevel|'
    '${normalizeHeadingKey(topicName)}|${normalizeHeadingKey(subtopicName ?? '')}';

List<EmbeddedContentSegment> buildEmbeddedContentSegments(List<EmbeddedLessonPlanSet> sets) {
  final segments = <EmbeddedContentSegment>[];
  // Tracks the next segment_order per group, and whether a group's heading
  // rows were already emitted (once per group, not once per lesson).
  final nextOrder = <String, int>{};
  final headingEmitted = <String>{};

  for (final set in sets) {
    for (final plan in set.lessonPlans) {
      final gradeLevels = plan.gradeLevel != null ? [plan.gradeLevel!] : set.gradeLevels;
      for (final gradeLevel in gradeLevels) {
        final groupKey = embeddedContentGroupKey(
          curriculumCode: set.curriculumCode,
          subjectCode: set.subjectCode,
          gradeLevel: gradeLevel,
          topicName: plan.topicName,
          subtopicName: plan.subtopicName,
        );

        int order() => nextOrder.update(groupKey, (v) => v + 1, ifAbsent: () => 1) - 1;

        void addSegment({required EmbeddedContentSegmentKind kind, String? stage, required String text}) {
          final trimmed = text.trim();
          if (trimmed.isEmpty) return;
          segments.add(EmbeddedContentSegment(
            groupKey: groupKey,
            curriculumCode: set.curriculumCode,
            subjectCode: set.subjectCode,
            gradeLevel: gradeLevel,
            topicName: plan.topicName,
            subtopicName: plan.subtopicName,
            kind: kind,
            stage: stage,
            segmentOrder: order(),
            text: trimmed,
          ));
        }

        if (headingEmitted.add(groupKey)) {
          addSegment(kind: EmbeddedContentSegmentKind.heading, text: plan.topicName);
          if (plan.subtopicName != null) {
            addSegment(kind: EmbeddedContentSegmentKind.heading, text: plan.subtopicName!);
          }
        }

        addSegment(kind: EmbeddedContentSegmentKind.body, text: plan.majorLearningPoint ?? '');
        addSegment(kind: EmbeddedContentSegmentKind.body, text: plan.lessonGoal ?? '');
        addSegment(kind: EmbeddedContentSegmentKind.body, text: plan.rationale ?? '');
        addSegment(kind: EmbeddedContentSegmentKind.body, text: plan.priorKnowledge ?? '');
        if (plan.objectives.isNotEmpty) {
          addSegment(kind: EmbeddedContentSegmentKind.body, text: plan.objectives.join('. '));
        }
        for (final row in plan.progression) {
          addSegment(
            kind: EmbeddedContentSegmentKind.body,
            stage: row.stage,
            text: '${row.teacherRole ?? ''} ${row.learnersRole ?? ''}'.trim(),
          );
        }
      }
    }
  }

  return segments;
}
