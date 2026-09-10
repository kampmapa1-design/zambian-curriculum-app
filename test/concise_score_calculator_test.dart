import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/marking_rubric.dart';
import 'package:zambian_curriculum_app/models/marking_script.dart';
import 'package:zambian_curriculum_app/services/concise_score_calculator.dart';

/// Permanent regression test for the deterministic Concise Marking scorer
/// (2026-09-10, per explicit request that "everything... adds up to only
/// 100 marks or 100 percent when the stipulated total number of questions
/// per section per script are marked"). The AI never does this arithmetic
/// — this does, offline — so these guarantees must not silently regress.
void main() {
  const calc = ConciseScoreCalculator();

  GradedAnswer ans(String label, double awarded, double max) => GradedAnswer(
        questionLabel: label,
        maxMarks: max,
        transcribedAnswer: '',
        marksAwarded: awarded,
        confidence: MarkingConfidence.high,
      );

  test('no rubric: plain percentage of every graded answer', () {
    final score = calc.compute(
      answers: [ans('1', 5, 10), ans('2', 8, 10), ans('3', 10, 10)],
      sectionByLabel: const {'1': null, '2': null, '3': null},
      rubric: null,
    );
    expect(score.rubricApplied, isFalse);
    expect(score.awardedMarks, 23);
    expect(score.possibleMarks, 30);
    expect(score.percentage, closeTo(76.67, 0.01));
    expect(score.sections, hasLength(1));
    expect(score.sections.single.name, 'All questions');
  });

  test('answer N of M: only the best required attempts count, excess is ignored', () {
    const rubric = MarkingRubric(
      sections: [
        RubricSection(name: 'Section A', questionsToAnswer: null, marksAllocated: 20),
        RubricSection(name: 'Section C', questionsToAnswer: 1, marksAllocated: 20),
      ],
      paperTotalMarks: 40,
      instructionsSummary: 'Answer all of A and any ONE of C.',
    );
    final score = calc.compute(
      answers: [
        ans('A1', 10, 10),
        ans('A2', 8, 10),
        ans('C1', 6, 20), // weaker C attempt — should be ignored
        ans('C2', 15, 20), // stronger C attempt — should be the one counted
      ],
      sectionByLabel: const {'A1': 'Section A', 'A2': 'Section A', 'C1': 'Section C', 'C2': 'Section C'},
      rubric: rubric,
    );

    expect(score.rubricApplied, isTrue);
    final sectionC = score.sections.firstWhere((s) => s.name == 'Section C');
    expect(sectionC.countedQuestions, 1);
    expect(sectionC.ignoredExcessQuestions, 1);
    expect(sectionC.countedLabels, ['C2']);
    expect(sectionC.ignoredLabels, ['C1']);
    expect(sectionC.awarded, 15);

    // A: 18/20, C: 15/20 -> 33/40 -> 82.5%
    expect(score.awardedMarks, 33);
    expect(score.possibleMarks, 40);
    expect(score.percentage, closeTo(82.5, 0.001));
  });

  test('section allocation scales raw question marks to the paper allocation', () {
    // Section maxMarks sum to 25, but the paper allocates the section 20.
    const rubric = MarkingRubric(
      sections: [RubricSection(name: 'Section B', questionsToAnswer: null, marksAllocated: 20)],
      paperTotalMarks: 20,
      instructionsSummary: '',
    );
    final score = calc.compute(
      answers: [ans('B1', 10, 15), ans('B2', 10, 10)], // 20/25 raw
      sectionByLabel: const {'B1': 'Section B', 'B2': 'Section B'},
      rubric: rubric,
    );
    // 20/25 of an allocation of 20 = 16; percentage 80.
    expect(score.awardedMarks, closeTo(16, 0.001));
    expect(score.possibleMarks, 20);
    expect(score.percentage, closeTo(80, 0.001));
  });

  test('a fully correct paper following the section rules scores exactly 100', () {
    const rubric = MarkingRubric(
      sections: [
        RubricSection(name: 'Section A', questionsToAnswer: null, marksAllocated: 40),
        RubricSection(name: 'Section B', questionsToAnswer: 2, marksAllocated: 60),
      ],
      paperTotalMarks: 100,
      instructionsSummary: 'Answer all of A, any TWO essays in B.',
    );
    final score = calc.compute(
      answers: [
        ans('A1', 20, 20),
        ans('A2', 20, 20),
        ans('B1', 30, 30),
        ans('B2', 30, 30),
        ans('B3', 0, 30), // a third essay the candidate shouldn't have attempted
      ],
      sectionByLabel: const {
        'A1': 'Section A', 'A2': 'Section A',
        'B1': 'Section B', 'B2': 'Section B', 'B3': 'Section B',
      },
      rubric: rubric,
    );
    expect(score.percentage, closeTo(100, 0.001));
    expect(score.roundedPercent, 100);
    expect(score.outOf100Label, '100 / 100');
  });

  test('ConciseScore survives a JSON round-trip (needed to regenerate marked scripts offline)', () {
    const rubric = MarkingRubric(
      sections: [
        RubricSection(name: 'Section A', questionsToAnswer: null, marksAllocated: 40),
        RubricSection(name: 'Section C', questionsToAnswer: 1, marksAllocated: 60),
      ],
      paperTotalMarks: 100,
      instructionsSummary: 'x',
    );
    final original = calc.compute(
      answers: [ans('A1', 15, 20), ans('A2', 20, 20), ans('C1', 40, 60), ans('C2', 10, 60)],
      sectionByLabel: const {'A1': 'Section A', 'A2': 'Section A', 'C1': 'Section C', 'C2': 'Section C'},
      rubric: rubric,
    );
    final restored = ConciseScore.fromJson(original.toJson());
    expect(restored.percentage, closeTo(original.percentage, 0.0001));
    expect(restored.awardedMarks, original.awardedMarks);
    expect(restored.possibleMarks, original.possibleMarks);
    expect(restored.rubricApplied, original.rubricApplied);
    expect(restored.sections.length, original.sections.length);
    expect(restored.sections.last.ignoredExcessQuestions, original.sections.last.ignoredExcessQuestions);
    expect(restored.outOf100Label, original.outOf100Label);
  });
}
