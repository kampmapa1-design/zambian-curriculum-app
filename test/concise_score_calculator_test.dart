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

  // -------------------------------------------------------------------
  // Stage 2 / Stage 4 (2026-09-22): the hard sanity-check safeguard, and a
  // permanent regression test reproducing the real incident it exists for —
  // a Zambian History paper where one miskeyed/misread mark (900 recorded
  // against a question worth 10) produced a "900 / 100" result that was
  // shown to a teacher as a real score. The scorer must now refuse to
  // output that, flag it for manual review, and still surface the raw
  // section-by-section breakdown so the teacher can find the miscount.
  // -------------------------------------------------------------------
  group('Stage 2 safeguard — never output an out-of-range score', () {
    test('THE HISTORY BUG: one miskeyed mark (900 of a possible 10) on an otherwise normal 100-mark paper '
        'is flagged, not silently shown as a real score', () {
      // A typical Zambian History paper: Section A short-answer questions
      // (no rubric-driven scaling — a plain sum), stated grand total 100.
      // Q7's mark was miskeyed as 900 (an extra zero) instead of 9.
      const rubric = MarkingRubric(sections: [], paperTotalMarks: 100, instructionsSummary: 'Answer all questions.');
      final score = calc.compute(
        answers: [
          ans('1', 8, 10), ans('2', 9, 10), ans('3', 7, 10), ans('4', 10, 10),
          ans('5', 6, 10), ans('6', 8, 10), ans('7', 900, 10), // <- the miskeyed mark
          ans('8', 9, 10), ans('9', 7, 10), ans('10', 8, 10),
        ],
        sectionByLabel: const {
          '1': null, '2': null, '3': null, '4': null, '5': null,
          '6': null, '7': null, '8': null, '9': null, '10': null,
        },
        rubric: rubric,
      );

      expect(score.structureError, isTrue);
      expect(score.structureErrorReason, contains('7'));
      expect(score.structureErrorReason, contains('900'));

      // Never a trustworthy number — never shown to a teacher as a real score.
      expect(score.outOf100Label, 'Needs review');
      expect(score.rawFractionLabel, 'Needs review');
      expect(score.roundedPercent, 0);

      // ...but the raw section-by-section breakdown IS still there, so the
      // teacher can actually find and fix the miscount.
      expect(score.sections, isNotEmpty);
      expect(score.sections.single.countedLabels, contains('7'));
    });

    test('a well-formed paper anywhere near this shape is completely unaffected (no false positive)', () {
      const rubric = MarkingRubric(sections: [], paperTotalMarks: 100, instructionsSummary: '');
      final score = calc.compute(
        answers: [for (var i = 1; i <= 10; i++) ans('$i', 8, 10)],
        sectionByLabel: {for (var i = 1; i <= 10; i++) '$i': null},
        rubric: rubric,
      );
      expect(score.structureError, isFalse);
      expect(score.structureErrorReason, isNull);
      expect(score.outOf100Label, '80 / 100');
    });

    test('a negative total is flagged, never shown as a negative score', () {
      final score = calc.compute(
        answers: [ans('1', -5, 10), ans('2', 3, 10)],
        sectionByLabel: const {'1': null, '2': null},
        rubric: null,
      );
      expect(score.structureError, isTrue);
      expect(score.structureErrorReason, contains('negative'));
    });

    test('marks awarded against a paper whose total comes out as zero is flagged, not silently shown as 0%', () {
      // maxMarks 0 keeps possible at 0 (a malformed/degenerate question), but
      // marksAwarded nonzero is still an impossible combination worth flagging.
      final score = calc.compute(
        answers: [ans('1', 5, 0)],
        sectionByLabel: const {'1': null},
        rubric: null,
      );
      expect(score.structureError, isTrue);
      expect(score.structureErrorReason, contains('zero'));
    });

    test('the 2% tolerance: right at the edge is fine, a hair beyond it is flagged', () {
      const rubric = MarkingRubric(sections: [], paperTotalMarks: 100, instructionsSummary: '');
      final atEdge = calc.compute(
        answers: [ans('1', 102, 100)], // exactly +2%
        sectionByLabel: const {'1': null},
        rubric: rubric,
      );
      expect(atEdge.structureError, isFalse);

      final beyondEdge = calc.compute(
        answers: [ans('1', 102.5, 100)], // +2.5%
        sectionByLabel: const {'1': null},
        rubric: rubric,
      );
      expect(beyondEdge.structureError, isTrue);
    });

    test('legitimate paper-total scaling of a normal, well-formed script never trips the safeguard', () {
      // Section maxMarks sum to 25 but the paper allocates 20 (a routine,
      // correct rescale) — this must never be mistaken for the bug.
      const rubric = MarkingRubric(
        sections: [RubricSection(name: 'Section B', questionsToAnswer: null, marksAllocated: 20)],
        paperTotalMarks: 20,
        instructionsSummary: '',
      );
      final score = calc.compute(
        answers: [ans('B1', 15, 15), ans('B2', 10, 10)], // 25/25 raw -> scaled to 20/20
        sectionByLabel: const {'B1': 'Section B', 'B2': 'Section B'},
        rubric: rubric,
      );
      expect(score.structureError, isFalse);
      expect(score.percentage, closeTo(100, 0.001));
    });

    test('ConciseScore survives a JSON round-trip with structureError set', () {
      const rubric = MarkingRubric(sections: [], paperTotalMarks: 100, instructionsSummary: '');
      final original = calc.compute(
        answers: [ans('1', 900, 10)],
        sectionByLabel: const {'1': null},
        rubric: rubric,
      );
      final restored = ConciseScore.fromJson(original.toJson());
      expect(restored.structureError, isTrue);
      expect(restored.structureErrorReason, original.structureErrorReason);
      expect(restored.outOf100Label, 'Needs review');
    });
  });
}
