import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/marking_scheme_node.dart';
import 'package:zambian_curriculum_app/models/marking_script.dart';
import 'package:zambian_curriculum_app/services/concise_score_calculator.dart';

/// Marking Scheme Structure Stage 7 (2026-09-22) — regression tests for the
/// real bug pattern Stage 6 closes: a section's "answer any N" logic must
/// select N TOP-LEVEL Questions, never accidentally letting one Question's
/// own Roman-numeral/lettered sub-parts count as extra independent
/// "questions" once its answers are flattened into a plain list.
GradedAnswer _ans(String label, {double marks = 5, double max = 10}) => GradedAnswer(
      questionLabel: label,
      maxMarks: max,
      transcribedAnswer: 'answer for $label',
      marksAwarded: marks,
      confidence: MarkingConfidence.high,
    );

void main() {
  const calculator = ConciseScoreCalculator();

  group('the exact bug pattern: sub-parts must nest under their question, never count as siblings', () {
    test('a question split into 3 Roman-numeral sub-parts is selected/rejected as ONE unit in "answer any 1"', () {
      // Section: answer any 1 of 2 questions. Question 1 is a single
      // leaf worth 10. Question 2 is split into three sub-parts (i, ii,
      // iii), each worth up to 10 (30 total) — the real shape that used
      // to let a flat "best N answers" picker treat 2(i)/2(ii)/2(iii) as
      // three separate candidate "questions" instead of one.
      const section = MarkingSchemeSection(
        name: 'Section A',
        requiredAnswerCount: 1,
        questions: [
          MarkingSchemeNode(label: '1', marks: 10),
          MarkingSchemeNode(label: '2', children: [
            MarkingSchemeNode(label: 'i', marks: 10),
            MarkingSchemeNode(label: 'ii', marks: 10),
            MarkingSchemeNode(label: 'iii', marks: 10),
          ]),
        ],
      );
      final answers = [
        _ans('1', marks: 4, max: 10),
        _ans('2(i)', marks: 9, max: 10),
        _ans('2(ii)', marks: 8, max: 10),
        _ans('2(iii)', marks: 7, max: 10),
      ];
      final score = calculator.computeForSections(answers: answers, sections: [section]);

      expect(score.structureError, isFalse);
      // Question 2's real combined total is 9+8+7=24 out of 30 — the
      // whole question, not just its best-scoring single sub-part.
      expect(score.sections.single.countedQuestions, 1, reason: 'exactly ONE top-level question counted, not 3 or 4');
      expect(score.sections.single.awarded, 24);
      expect(score.sections.single.possible, 30);
      expect(score.sections.single.countedLabels, ['2']);
      // Question 1 (worth only 10, lower-scoring as a whole) is the
      // ignored one — an aggregate comparison, not per-leaf.
      expect(score.sections.single.ignoredLabels, ['1']);
    });

    test('"answer any 2" never awards more than 2 full questions\' worth, even when one question has many sub-parts', () {
      const section = MarkingSchemeSection(
        name: 'Section B',
        requiredAnswerCount: 2,
        questions: [
          MarkingSchemeNode(label: '1', marks: 20),
          MarkingSchemeNode(label: '2', children: [
            MarkingSchemeNode(label: 'a', marks: 10),
            MarkingSchemeNode(label: 'b', marks: 10),
          ]), // 20 total
          MarkingSchemeNode(label: '3', marks: 20),
        ],
      );
      final answers = [
        _ans('1', marks: 20, max: 20),
        _ans('2(a)', marks: 10, max: 10),
        _ans('2(b)', marks: 10, max: 10),
        _ans('3', marks: 20, max: 20),
      ];
      final score = calculator.computeForSections(answers: answers, sections: [section]);
      // All three questions are worth full marks, but only 2 (40 marks'
      // worth) may ever be counted — never all 3 (60), and never a
      // number that implies more than 2 whole questions.
      expect(score.sections.single.countedQuestions, 2);
      expect(score.sections.single.possible, 40);
      expect(score.sections.single.awarded, 40);
    });
  });

  group('nested 3-level tree: Question -> Part -> Sub-part', () {
    test('every leaf across a lettered part AND its own Roman-numeral sub-parts rolls up into one question total', () {
      const section = MarkingSchemeSection(
        name: 'Section C',
        questions: [
          MarkingSchemeNode(label: '1', children: [
            MarkingSchemeNode(label: 'a', children: [
              MarkingSchemeNode(label: 'i', marks: 3),
              MarkingSchemeNode(label: 'ii', marks: 7),
            ]),
            MarkingSchemeNode(label: 'b', marks: 10),
          ]),
        ],
      );
      final answers = [
        _ans('1(a)(i)', marks: 3, max: 3),
        _ans('1(a)(ii)', marks: 5, max: 7),
        _ans('1(b)', marks: 8, max: 10),
      ];
      final score = calculator.computeForSections(answers: answers, sections: [section]);
      expect(score.sections.single.countedQuestions, 1);
      expect(score.sections.single.awarded, 16); // 3+5+8
      expect(score.sections.single.possible, 20); // 3+7+10
    });
  });

  group('no restriction (answer ALL) and multiple sections', () {
    test('requiredAnswerCount null counts every attempted question, across multiple sections', () {
      const sectionA = MarkingSchemeSection(
        name: 'A',
        questions: [MarkingSchemeNode(label: '1', marks: 10), MarkingSchemeNode(label: '2', marks: 10)],
      );
      const sectionB = MarkingSchemeSection(
        name: 'B',
        requiredAnswerCount: 1,
        questions: [MarkingSchemeNode(label: '3', marks: 20), MarkingSchemeNode(label: '4', marks: 20)],
      );
      final answers = [
        _ans('1', marks: 10, max: 10),
        _ans('2', marks: 5, max: 10),
        _ans('3', marks: 20, max: 20),
        _ans('4', marks: 5, max: 20),
      ];
      final score = calculator.computeForSections(answers: answers, sections: [sectionA, sectionB]);
      expect(score.awardedMarks, 35); // 10+5 (both of A) + 20 (best of B)
      expect(score.possibleMarks, 40); // 10+10 + 20
      expect(score.structureError, isFalse);
    });
  });

  group('the Stage 2 safeguard still applies to computeForSections', () {
    test('a leaf mismarked far beyond its own maximum is flagged, not silently shown', () {
      const section = MarkingSchemeSection(
        name: 'A',
        questions: [MarkingSchemeNode(label: '1', marks: 10), MarkingSchemeNode(label: '2', marks: 10)],
      );
      final answers = [_ans('1', marks: 900, max: 10), _ans('2', marks: 8, max: 10)];
      final score = calculator.computeForSections(answers: answers, sections: [section]);
      expect(score.structureError, isTrue);
      expect(score.structureErrorReason, contains('1'));
      expect(score.outOf100Label, 'Needs review');
    });
  });

  group('an unattempted question is excluded, not scored as zero-against-full-marks', () {
    test('a question with no graded answer at all for any of its leaves is skipped entirely', () {
      const section = MarkingSchemeSection(
        name: 'A',
        questions: [MarkingSchemeNode(label: '1', marks: 10), MarkingSchemeNode(label: '2', marks: 10)],
      );
      final score = calculator.computeForSections(answers: [_ans('1', marks: 8, max: 10)], sections: [section]);
      expect(score.sections.single.countedQuestions, 1);
      expect(score.sections.single.possible, 10);
    });
  });
}
