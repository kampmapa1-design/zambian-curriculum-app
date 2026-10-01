// Screen-level check for the OBC templates (2026-09-26): what a teacher
// actually sees when LessonPlanScreen opens with each OBC template — the
// Content / Learning Points field exists for Natural Sciences & Mathematics
// only, the last column is labelled per template, and the OBC-only defaults
// (homework text) are applied.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/lesson_plan.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';
import 'package:zambian_curriculum_app/screens/lesson_plan_screen.dart';
import 'package:zambian_curriculum_app/services/lesson_progression_generator.dart';

import 'support/sqlite_test_setup.dart';

/// A real Biology Grade 10 sub-topic, exactly as bundled in
/// assets/syllabi/biology_grade10.json (first sub-topic of topic 10.1).
SchemeOfWorkEntry _biologyEntry() {
  const competencies = [
    Competency(id: 1, sequenceNumber: 1, description: 'Identify the characteristics of living organisms'),
    Competency(id: 2, sequenceNumber: 2, description: 'Distinguish between living organisms and non-living things'),
    Competency(id: 3, sequenceNumber: 3, description: 'Describe life processes of living organisms'),
  ];
  const subTopic = SubTopic(
    id: 11,
    sequenceNumber: 1,
    name: '10.1.1 Characteristics of Living Organisms',
    objectives: const [],
    competencies: competencies,
  );
  final topic = Topic(
    id: 10,
    sequenceNumber: 1,
    name: '10.1 Living Organisms and Life Processes',
    subTopics: const [subTopic],
    objectives: const [],
    competencies: const [],
  );
  return SchemeOfWorkEntry(
    weekNumber: 1,
    topic: topic,
    subTopic: subTopic,
    objectives: const [],
    competencies: competencies,
  );
}

Future<void> _open(WidgetTester tester, LessonPlanTemplate template) async {
  await tester.binding.setSurfaceSize(const Size(800, 4000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: LessonPlanScreen(
      subjectName: 'Biology',
      curriculumCode: 'OBC_2013',
      subjectCode: 'BIO',
      gradeLevel: 10,
      entry: _biologyEntry(),
      template: template,
      isOneOff: true,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() async {
    await setUpTestDatabase();
  });

  testWidgets('Natural Sciences & Mathematics: Content / Learning Points field on every stage, populated', (tester) async {
    await _open(tester, defaultObcNaturalSciencesMathematicsLessonPlanTemplate);

    expect(find.text('Content / Learning Points'), findsNWidgets(3), reason: 'Introduction, Development, Conclusion');
    expect(find.text('ASSESSMENT/EVIDENCE'), findsNWidgets(3));
    expect(find.text('Assessment Criteria'), findsNothing);
    // The Development stage's learning points are the real syllabus outcomes.
    expect(find.textContaining('Identify the characteristics of living organisms'), findsWidgets);
    // Section 10's default text was applied (OBC layouts only) — it sits at the very bottom of a long list.
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pump();
    expect(find.text(defaultObcHomeworkText), findsOneWidget);
  });

  testWidgets('Social Sciences: no Content field at all; last column reads Assessment Criteria', (tester) async {
    await _open(tester, defaultObcSocialSciencesLessonPlanTemplate);

    expect(find.text('Content / Learning Points'), findsNothing);
    expect(find.text('Assessment Criteria'), findsNWidgets(3));
    expect(find.text('ASSESSMENT/EVIDENCE'), findsNothing);
    expect(find.text('Teacher\'s Role'), findsNWidgets(3));
    expect(find.text('Learners\' Role'), findsNWidgets(3));
  });

  testWidgets('Legacy templates are unchanged on screen (no Content field, Assessment Criteria label)', (tester) async {
    await _open(tester, defaultCdcLessonPlanTemplate);

    expect(find.text('Content / Learning Points'), findsNothing);
    expect(find.text('Assessment Criteria'), findsWidgets);
    expect(find.text(defaultObcHomeworkText), findsNothing, reason: 'OBC-only default must not leak into other templates');
  });
}
