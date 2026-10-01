import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/embedded_content_segment.dart';
import 'package:zambian_curriculum_app/models/embedded_lesson_plan.dart';
import 'package:zambian_curriculum_app/services/embedded_content_index_builder.dart';

EmbeddedLessonPlanSet _set({
  String curriculumCode = 'CBC_2023',
  String subjectCode = 'HIST',
  List<int> gradeLevels = const [1],
  required List<EmbeddedLessonPlan> plans,
}) =>
    EmbeddedLessonPlanSet(
      source: 'test',
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevels: gradeLevels,
      lessonPlans: plans,
    );

void main() {
  group('buildEmbeddedContentSegments', () {
    test('two lessons sharing one sub-topic pool into a single group, in source order', () {
      final set = _set(plans: [
        const EmbeddedLessonPlan(
          topicName: '1.1 Topic',
          subtopicName: '1.1.1 Sub',
          sequenceLabel: 'Lesson 1 of 2',
          majorLearningPoint: 'First point.',
          progression: [EmbeddedProgressionRow(stage: 'Introduction', teacherRole: 'Teach A', learnersRole: 'Learn A')],
        ),
        const EmbeddedLessonPlan(
          topicName: '1.1 Topic',
          subtopicName: '1.1.1 Sub',
          sequenceLabel: 'Lesson 2 of 2',
          majorLearningPoint: 'Second point.',
          progression: [EmbeddedProgressionRow(stage: 'Development', teacherRole: 'Teach B', learnersRole: 'Learn B')],
        ),
      ]);

      final segments = buildEmbeddedContentSegments([set]);
      final groupKeys = segments.map((s) => s.groupKey).toSet();
      expect(groupKeys, hasLength(1));

      final heading = segments.where((s) => s.kind == EmbeddedContentSegmentKind.heading).toList();
      // Heading rows emitted exactly once per group, not once per lesson.
      expect(heading, hasLength(2)); // topic name + sub-topic name

      final body = segments.where((s) => s.kind == EmbeddedContentSegmentKind.body).toList()
        ..sort((a, b) => a.segmentOrder.compareTo(b.segmentOrder));
      expect(body.map((s) => s.text), containsAllInOrder(['First point.', 'Teach A Learn A', 'Second point.', 'Teach B Learn B']));
    });

    test('a plan with no sub-topic groups under (topic, no sub-topic) and only emits a topic heading', () {
      final set = _set(plans: const [
        EmbeddedLessonPlan(topicName: 'Standalone Topic', majorLearningPoint: 'Content.'),
      ]);
      final segments = buildEmbeddedContentSegments([set]);
      final heading = segments.where((s) => s.kind == EmbeddedContentSegmentKind.heading).toList();
      expect(heading, hasLength(1));
      expect(heading.single.text, 'Standalone Topic');
    });

    test('a plan with a null gradeLevel is expanded across every grade in its set', () {
      final set = _set(
        gradeLevels: const [10, 11],
        plans: const [EmbeddedLessonPlan(topicName: 'Shared Topic', majorLearningPoint: 'Content.')],
      );
      final segments = buildEmbeddedContentSegments([set]);
      expect(segments.map((s) => s.gradeLevel).toSet(), {10, 11});
      expect(segments.map((s) => s.groupKey).toSet(), hasLength(2), reason: 'one group per grade');
    });

    test('a plan-specific gradeLevel overrides the set — only that one grade gets segments', () {
      final set = _set(
        gradeLevels: const [10, 11],
        plans: const [EmbeddedLessonPlan(topicName: 'Grade-Specific Topic', gradeLevel: 10, majorLearningPoint: 'Content.')],
      );
      final segments = buildEmbeddedContentSegments([set]);
      expect(segments.map((s) => s.gradeLevel).toSet(), {10});
    });

    test('blank/null fields never produce an empty segment', () {
      final set = _set(plans: const [EmbeddedLessonPlan(topicName: 'Topic', lessonGoal: '   ')]);
      final segments = buildEmbeddedContentSegments([set]);
      expect(segments.every((s) => s.text.trim().isNotEmpty), isTrue);
    });

    test('an empty set list produces no segments, not a crash', () {
      expect(buildEmbeddedContentSegments(const []), isEmpty);
    });
  });

  group('embeddedContentGroupKey', () {
    test('is case/whitespace-insensitive on topic and sub-topic names', () {
      final a = embeddedContentGroupKey(curriculumCode: 'c', subjectCode: 's', gradeLevel: 1, topicName: '  Topic  One ', subtopicName: 'Sub');
      final b = embeddedContentGroupKey(curriculumCode: 'C', subjectCode: 'S', gradeLevel: 1, topicName: 'topic one', subtopicName: 'sub');
      expect(a, b);
    });

    test('different grades never collide', () {
      final a = embeddedContentGroupKey(curriculumCode: 'c', subjectCode: 's', gradeLevel: 1, topicName: 'x');
      final b = embeddedContentGroupKey(curriculumCode: 'c', subjectCode: 's', gradeLevel: 2, topicName: 'x');
      expect(a, isNot(b));
    });
  });
}
