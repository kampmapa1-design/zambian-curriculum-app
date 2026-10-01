import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/embedded_lesson_plan.dart';
import 'package:zambian_curriculum_app/services/fine_tune_topic_builder.dart';

void main() {
  const builder = FineTuneTopicBuilder();
  int nextId() {
    _idCounter -= 1;
    return _idCounter;
  }

  setUp(() => _idCounter = 0);

  test('splits real "Competence"-labeled objective strings into competencies, everything else into objectives', () {
    final plans = [
      const EmbeddedLessonPlan(
        topicName: 'Broad Topic',
        subtopicName: 'Sub A',
        majorLearningPoint: 'Explaining the core idea.',
        lessonGoal: 'By the end of the lesson, learners will be able to explain the core idea.',
        objectives: [
          'General Competence: Communication',
          'Specific Competence 1.1.1: Explain the core idea.',
        ],
      ),
    ];
    final topic = builder.build(topicName: 'Broad Topic', subtopicName: 'Sub A', plans: plans, nextSyntheticId: nextId);

    expect(topic.name, 'Sub A');
    expect(topic.description, 'Explaining the core idea.');
    expect(topic.competencies.map((c) => c.description), containsAll(['General Competence: Communication', 'Specific Competence 1.1.1: Explain the core idea.']));
    expect(topic.objectives.map((o) => o.description), contains('By the end of the lesson, learners will be able to explain the core idea.'));
    expect(topic.id, lessThan(0), reason: 'a synthetic topic — never a real database row');
  });

  test('pools real content across multiple lessons sharing the same sub-topic, without duplicating identical text', () {
    final plans = [
      const EmbeddedLessonPlan(
        topicName: 'Broad Topic',
        subtopicName: 'Sub B',
        lessonGoal: 'Goal one.',
        objectives: ['General Competence: Communication'],
      ),
      const EmbeddedLessonPlan(
        topicName: 'Broad Topic',
        subtopicName: 'Sub B',
        lessonGoal: 'Goal two.',
        objectives: ['General Competence: Communication'], // same competency repeated across lessons
      ),
    ];
    final topic = builder.build(topicName: 'Broad Topic', subtopicName: 'Sub B', plans: plans, nextSyntheticId: nextId);
    expect(topic.competencies, hasLength(1), reason: 'deduplicated identical real text');
    expect(topic.objectives.map((o) => o.description), containsAll(['Goal one.', 'Goal two.']));
  });

  test('never produces a topic with both competencies and objectives empty when any real objective text exists', () {
    final plans = [
      const EmbeddedLessonPlan(
        topicName: 'Broad Topic',
        subtopicName: 'Sub C',
        objectives: ['Just a plain phrase, not labeled as a competence.'],
      ),
    ];
    final topic = builder.build(topicName: 'Broad Topic', subtopicName: 'Sub C', plans: plans, nextSyntheticId: nextId);
    expect(topic.competencies.length + topic.objectives.length, greaterThan(0));
  });

  test('a description falls back to null (not a fabricated sentence) when no plan has a majorLearningPoint', () {
    final plans = [const EmbeddedLessonPlan(topicName: 'Broad Topic', subtopicName: 'Sub D', lessonGoal: 'A goal.')];
    final topic = builder.build(topicName: 'Broad Topic', subtopicName: 'Sub D', plans: plans, nextSyntheticId: nextId);
    expect(topic.description, isNull);
  });
}

int _idCounter = 0;
