// Regression coverage for LessonPlanAiResult.mergedProgression — the seam
// between the always-available offline lesson plan and its optional AI
// upgrade. The real requirement (see lesson_plan_ai_service.dart's own doc
// comment) is that a failed or declined AI call must never lose content a
// teacher already has: the offline generator fills every stage first, and
// the AI merge only OVERWRITES the stages it actually returned, by stage
// name, leaving everything else exactly as it was.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/lesson_plan.dart';
import 'package:zambian_curriculum_app/services/lesson_plan_ai_service.dart';

void main() {
  group('mergedProgression', () {
    test('overwrites teacherRole/learnersRole/assessmentCriteria for a stage the AI returned', () {
      const existing = [
        LessonProgressionRow(
          stage: 'Introduction',
          teacherRole: 'offline teacher role',
          learnersRole: 'offline learners role',
          assessmentCriteria: 'offline criteria',
        ),
      ];
      const aiResult = LessonPlanAiResult(
        rationale: '',
        priorKnowledge: '',
        tlm: '',
        expectedStandard: '',
        progression: [
          LessonPlanAiProgressionRow(
            stage: 'Introduction',
            teacherRole: 'AI teacher role',
            learnersRole: 'AI learners role',
            assessmentCriteria: 'AI criteria',
          ),
        ],
      );

      final merged = aiResult.mergedProgression(existing);

      expect(merged, hasLength(1));
      expect(merged.single.teacherRole, 'AI teacher role');
      expect(merged.single.learnersRole, 'AI learners role');
      expect(merged.single.assessmentCriteria, 'AI criteria');
    });

    test('leaves a stage the AI did not return completely untouched — never blanked', () {
      const existing = [
        LessonProgressionRow(
          stage: 'Introduction',
          teacherRole: 'offline teacher role',
          learnersRole: 'offline learners role',
          assessmentCriteria: 'offline criteria',
        ),
        LessonProgressionRow(
          stage: 'Custom Reflection Stage',
          teacherRole: "teacher's own hand-written content for a custom template stage",
          learnersRole: 'existing learners content',
          assessmentCriteria: 'existing criteria',
        ),
      ];
      // The AI result only covers "Introduction" — e.g. because the caller
      // only asked about that stage, or a custom stage name the model was
      // never told about.
      const aiResult = LessonPlanAiResult(
        rationale: '',
        priorKnowledge: '',
        tlm: '',
        expectedStandard: '',
        progression: [
          LessonPlanAiProgressionRow(
            stage: 'Introduction',
            teacherRole: 'AI teacher role',
            learnersRole: 'AI learners role',
            assessmentCriteria: 'AI criteria',
          ),
        ],
      );

      final merged = aiResult.mergedProgression(existing);

      expect(merged, hasLength(2));
      final customStage = merged.firstWhere((r) => r.stage == 'Custom Reflection Stage');
      expect(customStage.teacherRole, "teacher's own hand-written content for a custom template stage",
          reason: 'a stage the AI never returned must survive the merge completely unchanged');
      expect(customStage.learnersRole, 'existing learners content');
      expect(customStage.assessmentCriteria, 'existing criteria');
    });

    test('matches stage names case- and whitespace-insensitively', () {
      const existing = [
        LessonProgressionRow(stage: '  introduction  ', teacherRole: 'offline'),
      ];
      const aiResult = LessonPlanAiResult(
        rationale: '',
        priorKnowledge: '',
        tlm: '',
        expectedStandard: '',
        progression: [
          LessonPlanAiProgressionRow(
            stage: 'INTRODUCTION',
            teacherRole: 'AI teacher role',
            learnersRole: 'AI learners role',
            assessmentCriteria: 'AI criteria',
          ),
        ],
      );

      final merged = aiResult.mergedProgression(existing);

      expect(merged.single.teacherRole, 'AI teacher role');
    });

    test('never touches durationMinutes, even for a matched stage', () {
      const existing = [
        LessonProgressionRow(stage: 'Introduction', teacherRole: 'offline', durationMinutes: '15'),
      ];
      const aiResult = LessonPlanAiResult(
        rationale: '',
        priorKnowledge: '',
        tlm: '',
        expectedStandard: '',
        progression: [
          LessonPlanAiProgressionRow(
            stage: 'Introduction',
            teacherRole: 'AI teacher role',
            learnersRole: 'AI learners role',
            assessmentCriteria: 'AI criteria',
          ),
        ],
      );

      final merged = aiResult.mergedProgression(existing);

      expect(merged.single.durationMinutes, '15', reason: 'duration is the teacher\'s own setting, never AI-derived');
    });

    test('an AI result with an empty progression list leaves every stage untouched (declined/no-op case)', () {
      const existing = [
        LessonProgressionRow(stage: 'Introduction', teacherRole: 'offline intro'),
        LessonProgressionRow(stage: 'Development', teacherRole: 'offline development'),
      ];
      const aiResult = LessonPlanAiResult(
        rationale: '',
        priorKnowledge: '',
        tlm: '',
        expectedStandard: '',
        progression: [],
      );

      final merged = aiResult.mergedProgression(existing);

      expect(merged, existing, reason: 'an empty AI progression (or the AI call never happening at all) must be a pure no-op');
    });

    test('preserves the original stage order regardless of AI response order', () {
      const existing = [
        LessonProgressionRow(stage: 'Introduction', teacherRole: 'a'),
        LessonProgressionRow(stage: 'Development', teacherRole: 'b'),
        LessonProgressionRow(stage: 'Conclusion', teacherRole: 'c'),
      ];
      const aiResult = LessonPlanAiResult(
        rationale: '',
        priorKnowledge: '',
        tlm: '',
        expectedStandard: '',
        progression: [
          LessonPlanAiProgressionRow(
            stage: 'Conclusion',
            teacherRole: 'AI c',
            learnersRole: '',
            assessmentCriteria: '',
          ),
          LessonPlanAiProgressionRow(
            stage: 'Introduction',
            teacherRole: 'AI a',
            learnersRole: '',
            assessmentCriteria: '',
          ),
        ],
      );

      final merged = aiResult.mergedProgression(existing);

      expect(merged.map((r) => r.stage).toList(), ['Introduction', 'Development', 'Conclusion']);
      expect(merged[0].teacherRole, 'AI a');
      expect(merged[1].teacherRole, 'b', reason: 'Development was never in the AI response — untouched');
      expect(merged[2].teacherRole, 'AI c');
    });
  });
}
