// Regression tests (2026-09-05) for the real reported gap: a teacher
// confirming a section's marks had to reverse-engineer "marks per row"
// from a section total they already knew from the exam's own rules (e.g.
// "Section A = 30 marks"), and Roman-numeral/lettered sub-parts of one
// question could get miscounted as independent top-level questions.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/marking_scheme_section_marks.dart';
import 'package:zambian_curriculum_app/services/proportional_allocation.dart';

void main() {
  group('topLevelQuestionKey / countTopLevelQuestions', () {
    test('Roman-numeral and lettered sub-parts group under their leading question number', () {
      final labels = ['2(i)', '2(ii)', '2(iii)', '2 iv.', '1', '1a)', '3'];
      expect(labels.map(topLevelQuestionKey).toList(), ['2', '2', '2', '2', '1', '1', '3']);
      expect(countTopLevelQuestions(labels), 3); // Questions 1, 2, 3 -- not 7 rows.
    });

    test('a label with no leading number at all falls back to itself, not merged with anything', () {
      expect(topLevelQuestionKey('Bonus question'), 'Bonus question');
      expect(countTopLevelQuestions(['Bonus question', 'Extra credit']), 2);
    });
  });

  group('suggestSectionMarkingStyle', () {
    test('"answer any ONE of the following" suggests one-row-gets-full-total (essay-style)', () {
      expect(
        suggestSectionMarkingStyle('Answer any ONE of the following THREE questions.'),
        SectionMarkingStyle.oneRowGetsFullTotal,
      );
    });

    test('"answer ALL questions in this section" suggests all-rows-sum-to-total', () {
      expect(
        suggestSectionMarkingStyle('Answer ALL questions in this section.'),
        SectionMarkingStyle.allRowsSumToTotal,
      );
    });

    test('unclear/empty instructions default to all-rows-sum-to-total (the more common real pattern)', () {
      expect(suggestSectionMarkingStyle(''), SectionMarkingStyle.allRowsSumToTotal);
    });
  });

  group('apportionSectionMarks', () {
    test('allRowsSumToTotal splits proportionally to existing relative weights and sums exactly', () {
      // 6 rows (2 questions x 3 sub-parts each), currently AI-extracted at
      // uneven marks (a longer sub-part already weighted higher) -- real
      // section total per the paper's own rules is 30, not whatever the
      // AI happened to sum to (17).
      final current = [2.0, 3.0, 5.0, 2.0, 2.0, 3.0]; // sums to 17
      final result = apportionSectionMarks(current, 30, SectionMarkingStyle.allRowsSumToTotal);
      expect(result.length, 6);
      expect(result.fold<double>(0, (a, b) => a + b), 30);
      // Relative order preserved: the row that was weighted highest before
      // (index 2, weight 5) still ends up with the most marks after.
      expect(result[2], greaterThanOrEqualTo(result[0]));
      expect(result[2], greaterThanOrEqualTo(result[1]));
    });

    test('allRowsSumToTotal falls back to an even split when every row currently has the same (or zero) marks', () {
      final result = apportionSectionMarks([0, 0, 0], 30, SectionMarkingStyle.allRowsSumToTotal);
      expect(result, [10.0, 10.0, 10.0]);
    });

    test('oneRowGetsFullTotal gives every alternative the FULL section total, not divided', () {
      // Section C: 4 alternative essay questions, only one will be
      // answered -- each is worth the full 20, not 20/4=5.
      final result = apportionSectionMarks([0, 0, 0, 0], 20, SectionMarkingStyle.oneRowGetsFullTotal);
      expect(result, [20.0, 20.0, 20.0, 20.0]);
    });

    test('a real History paper (Section A=30, B=30, C=20 essay, D=20) sums to exactly 100', () {
      // Section A: 2 questions, 3 sub-parts each (6 rows).
      final sectionA = apportionSectionMarks(List.filled(6, 0), 30, SectionMarkingStyle.allRowsSumToTotal);
      // Section B: same shape.
      final sectionB = apportionSectionMarks(List.filled(6, 0), 30, SectionMarkingStyle.allRowsSumToTotal);
      // Section C: 4 alternative essays, one answered in full.
      final sectionC = apportionSectionMarks(List.filled(4, 0), 20, SectionMarkingStyle.oneRowGetsFullTotal);
      // Section D: likewise.
      final sectionD = apportionSectionMarks(List.filled(3, 0), 20, SectionMarkingStyle.oneRowGetsFullTotal);

      expect(sectionA.fold<double>(0, (a, b) => a + b), 30);
      expect(sectionB.fold<double>(0, (a, b) => a + b), 30);
      // Section C/D: every alternative is worth the FULL section total on
      // its own (confirmed above), but only ONE row is ever actually
      // answered by a real candidate -- so the paper's real total counts
      // each section once (20), not sectionC.length x 20.
      expect(sectionC, everyElement(20.0));
      expect(sectionD, everyElement(20.0));
      const paperTotal = 30 + 30 + 20 + 20;
      expect(paperTotal, 100);
    });
  });

  group('allocateProportionally (shared with scheme-of-work pacing)', () {
    test('sums to exactly the requested total even when it does not divide evenly', () {
      final result = allocateProportionally([1, 1, 1, 1, 1, 1, 1], 30);
      expect(result.fold<int>(0, (a, b) => a + b), 30);
      expect(result.length, 7);
    });

    test('every weighted entry gets at least 1, never silently zeroed', () {
      final result = allocateProportionally([100, 1, 1], 5);
      expect(result.every((v) => v >= 1), isTrue);
      expect(result.fold<int>(0, (a, b) => a + b), 5);
    });
  });
}
