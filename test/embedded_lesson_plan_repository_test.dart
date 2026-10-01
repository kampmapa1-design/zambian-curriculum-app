// A real, permanent regression test (2026-09-18) — not a throwaway script.
// This engine has a DOCUMENTED, REAL history of exactly one failure mode:
// a subject_code (or curriculum_code) typo/mismatch in one of
// assets/lesson_plans/*.json silently makes every one of that file's real,
// teacher-authored lesson plans permanently unmatchable —
// EmbeddedLessonPlanRepository.find() just returns an empty list, with no
// error, no crash, nothing visibly wrong. This exact bug class has shipped
// silently before (98 lesson plans across two files, discovered only by
// deliberate later investigation) and was found AGAIN, live, while writing
// this very test: civic_education_grade10-12.json's subject_code was
// "civic_education" instead of the real syllabus code "CIVIC", silently
// orphaning all 89 of that file's real lesson plans. Fixed alongside this
// test (see that file's own diff) — this suite exists so the NEXT one
// doesn't need a human to notice by accident.
//
// Approach: load every bundled file's raw JSON directly (this test's own
// ground truth, independent of the repository under test), then call the
// REAL EmbeddedLessonPlanRepository.find() — the exact production
// code path, including its on-device asset loading via rootBundle — with
// each plan's own recorded key, and assert it finds itself. A file whose
// codes have drifted from the real syllabus fails this test immediately,
// the same day the drift happens, rather than shipping silently inert.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/embedded_lesson_plan.dart';
import 'package:zambian_curriculum_app/services/embedded_lesson_plan_repository.dart';

List<EmbeddedLessonPlanSet> _loadAllFromDisk() {
  final manifest = jsonDecode(File('assets/lesson_plans/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final files = (manifest['files'] as List).cast<String>();
  return [
    for (final fileName in files)
      EmbeddedLessonPlanSet.fromJson(
        jsonDecode(File('assets/lesson_plans/$fileName').readAsStringSync()) as Map<String, dynamic>,
      ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sets = _loadAllFromDisk();

  test('at least one embedded lesson plan set is bundled', () {
    expect(sets, isNotEmpty);
  });

  for (final set in sets) {
    group('${set.subjectCode} (${set.curriculumCode}, grades ${set.gradeLevels})', () {
      test('every one of its ${set.lessonPlans.length} lesson plan(s) is findable by its own real key', () async {
        final repo = EmbeddedLessonPlanRepository();
        final neverMatched = <String>[];

        for (final plan in set.lessonPlans) {
          final gradeToTry = plan.gradeLevel ?? set.gradeLevels.first;
          final matches = await repo.find(
            curriculumCode: set.curriculumCode,
            subjectCode: set.subjectCode,
            gradeLevel: gradeToTry,
            topicName: plan.topicName,
            subtopicName: plan.subtopicName,
          );
          final foundItself = matches.any(
            (m) =>
                m.topicName == plan.topicName &&
                m.subtopicName == plan.subtopicName &&
                m.sequenceLabel == plan.sequenceLabel,
          );
          if (!foundItself) {
            neverMatched.add(
              '"${plan.topicName}"${plan.subtopicName == null ? '' : ' / "${plan.subtopicName}"'}'
              '${plan.sequenceLabel == null ? '' : ' (${plan.sequenceLabel})'}',
            );
          }
        }

        expect(
          neverMatched,
          isEmpty,
          reason:
              'These real lesson plans in ${set.source.substring(0, set.source.length.clamp(0, 60))}... are '
              'silently inert — find() never returns them for their own recorded topic/subtopic/grade. This is '
              'exactly the subject_code/curriculum_code-mismatch bug class this suite exists to catch:\n'
              '${neverMatched.join('\n')}',
        );
      });
    });
  }

  group('matcher does not over-match', () {
    test('a genuinely wrong subject code matches nothing, even for a real topic name', () async {
      final repo = EmbeddedLessonPlanRepository();
      final anySet = sets.first;
      final anyPlan = anySet.lessonPlans.first;

      final matches = await repo.find(
        curriculumCode: anySet.curriculumCode,
        subjectCode: 'NOT_A_REAL_SUBJECT_CODE',
        gradeLevel: anyPlan.gradeLevel ?? anySet.gradeLevels.first,
        topicName: anyPlan.topicName,
        subtopicName: anyPlan.subtopicName,
      );

      expect(matches, isEmpty);
    });

    test('a genuinely wrong curriculum code matches nothing, even for a real topic name', () async {
      final repo = EmbeddedLessonPlanRepository();
      final anySet = sets.first;
      final anyPlan = anySet.lessonPlans.first;

      final matches = await repo.find(
        curriculumCode: 'NOT_A_REAL_CURRICULUM',
        subjectCode: anySet.subjectCode,
        gradeLevel: anyPlan.gradeLevel ?? anySet.gradeLevels.first,
        topicName: anyPlan.topicName,
        subtopicName: anyPlan.subtopicName,
      );

      expect(matches, isEmpty);
    });

    test('a grade level outside the set\'s own gradeLevels matches nothing', () async {
      final repo = EmbeddedLessonPlanRepository();
      final anySet = sets.first;
      final anyPlan = anySet.lessonPlans.first;
      final outsideGrade = ([for (var g = 1; g <= 20; g++) g]..removeWhere(anySet.gradeLevels.contains)).first;

      final matches = await repo.find(
        curriculumCode: anySet.curriculumCode,
        subjectCode: anySet.subjectCode,
        gradeLevel: outsideGrade,
        topicName: anyPlan.topicName,
        subtopicName: anyPlan.subtopicName,
      );

      expect(matches, isEmpty);
    });

    test('topic name matching is case/whitespace-insensitive but still requires the real words to match', () async {
      final repo = EmbeddedLessonPlanRepository();
      final anySet = sets.first;
      final anyPlan = anySet.lessonPlans.first;

      final matchesShouted = await repo.find(
        curriculumCode: anySet.curriculumCode,
        subjectCode: anySet.subjectCode,
        gradeLevel: anyPlan.gradeLevel ?? anySet.gradeLevels.first,
        topicName: '  ${anyPlan.topicName.toUpperCase()}  ',
        subtopicName: anyPlan.subtopicName,
      );
      expect(matchesShouted, isNotEmpty, reason: 'case/whitespace differences alone must not break a real match');

      final matchesWrongTopic = await repo.find(
        curriculumCode: anySet.curriculumCode,
        subjectCode: anySet.subjectCode,
        gradeLevel: anyPlan.gradeLevel ?? anySet.gradeLevels.first,
        topicName: 'Definitely Not A Real Topic Name In This File',
        subtopicName: anyPlan.subtopicName,
      );
      expect(matchesWrongTopic, isEmpty);
    });
  });
}
