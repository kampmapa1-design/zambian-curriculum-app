import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/home_assignment.dart';

/// Real bug (owner report, 2026-09-28): a references list passed to
/// generateHomeAssignment for the AI's OWN grounding could come back as a
/// spurious extra "question" in the AI's response, which then flowed
/// straight into the auto-saved marking key and from there into Lesson
/// Plan's "Related Marking Keys" section as visible junk. Guards the
/// client-side defense-in-depth filter (the prompt itself was also fixed,
/// server-side, not covered by this Dart test).
void main() {
  group('isLikelyReferencesHeading', () {
    test('a bare "References" number or text is flagged', () {
      expect(isLikelyReferencesHeading(number: 'References', text: 'References'), isTrue);
      expect(isLikelyReferencesHeading(number: '5', text: 'References'), isTrue);
      expect(isLikelyReferencesHeading(number: '5', text: 'References:'), isTrue);
      expect(isLikelyReferencesHeading(number: '5', text: '  Reference:  '), isTrue);
    });

    test('Bibliography is flagged the same way', () {
      expect(isLikelyReferencesHeading(number: 'Bibliography', text: ''), isTrue);
      expect(isLikelyReferencesHeading(number: '3', text: 'Bibliography:'), isTrue);
    });

    test('a real question that merely mentions "references" mid-sentence is NEVER flagged', () {
      expect(
        isLikelyReferencesHeading(
          number: '4',
          text: 'Explain how the Bill of Rights references citizens\' freedoms in Zambia.',
        ),
        isFalse,
      );
    });

    test('an ordinary numbered question is never flagged', () {
      expect(isLikelyReferencesHeading(number: '1', text: 'Define photosynthesis.'), isFalse);
    });
  });

  group('HomeAssignmentResult.fromMap filters references-heading questions', () {
    test('a spurious references question is dropped, real questions survive', () {
      final result = HomeAssignmentResult.fromMap({
        'title': 'Test',
        'instructions': 'Do it.',
        'questions': [
          {'number': '1', 'text': 'Define photosynthesis.', 'maxMarks': 5},
          {'number': 'References', 'text': 'Teachers\' Guide for Biology', 'maxMarks': 0},
        ],
        'markingKey': [
          {'number': '1', 'expectedAnswerOrKeywords': 'the process by which plants make food'},
          {'number': 'References', 'expectedAnswerOrKeywords': 'Teachers\' Guide for Biology'},
        ],
        'notes': '',
      });
      expect(result.questions, hasLength(1));
      expect(result.questions.first.number, '1');
    });
  });
}
