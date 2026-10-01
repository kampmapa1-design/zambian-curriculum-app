import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/marking_key_tree_parser.dart';

void main() {
  test('parses a real 3-level shape: Section -> Question -> Part -> Sub-part', () {
    final raw = [
      {
        'name': 'Section A',
        'answerInstructions': 'Answer any ONE question from this section',
        'requiredAnswerCount': 1,
        'questions': [
          {
            'label': '1',
            'expectedAnswerOrKeywords': '',
            'marks': 0,
            'parts': [
              {
                'label': 'a',
                'expectedAnswerOrKeywords': '',
                'marks': 0,
                'subParts': [
                  {'label': 'i', 'expectedAnswerOrKeywords': 'x', 'marks': 3},
                  {'label': 'ii', 'expectedAnswerOrKeywords': 'y', 'marks': 7},
                ],
              },
            ],
          },
        ],
      },
    ];
    final sections = parseMarkingKeySectionTree(raw);
    expect(sections, hasLength(1));
    expect(sections.single.name, 'Section A');
    expect(sections.single.requiredAnswerCount, 1);
    final flat = sections.single.flattenedQuestions();
    expect(flat.map((q) => q.label), ['1(a)(i)', '1(a)(ii)']);
    expect(sections.single.totalMarksIfAllAnswered, 10);
  });

  test('parses a 2-level shape: Question -> Roman-numeral parts directly (no letter layer)', () {
    final raw = [
      {
        'name': '',
        'answerInstructions': '',
        'requiredAnswerCount': null,
        'questions': [
          {
            'label': '2',
            'expectedAnswerOrKeywords': '',
            'marks': 0,
            'parts': [
              {'label': 'i', 'expectedAnswerOrKeywords': 'a', 'marks': 5, 'subParts': []},
              {'label': 'ii', 'expectedAnswerOrKeywords': 'b', 'marks': 5, 'subParts': []},
            ],
          },
        ],
      },
    ];
    final sections = parseMarkingKeySectionTree(raw);
    final flat = sections.single.flattenedQuestions();
    expect(flat.map((q) => q.label), ['2(i)', '2(ii)']);
    expect(sections.single.requiredAnswerCount, isNull);
  });

  test('a plain leaf question with no parts at all parses correctly', () {
    final raw = [
      {
        'name': 'Section B',
        'answerInstructions': '',
        'requiredAnswerCount': null,
        'questions': [
          {'label': '1', 'expectedAnswerOrKeywords': 'answer', 'marks': 10, 'parts': []},
        ],
      },
    ];
    final flat = parseMarkingKeySectionTree(raw).single.flattenedQuestions();
    expect(flat.single.label, '1');
    expect(flat.single.maxMarks, 10);
    expect(flat.single.expectedAnswerOrKeywords, 'answer');
  });

  test('malformed input degrades gracefully rather than throwing', () {
    expect(parseMarkingKeySectionTree(null), isEmpty);
    expect(parseMarkingKeySectionTree('not a list'), isEmpty);
    expect(parseMarkingKeySectionTree([1, 2, 'garbage']), isEmpty);
    expect(
      parseMarkingKeySectionTree([
        {'name': 'X'} // missing questions/answerInstructions/requiredAnswerCount entirely
      ]).single.questions,
      isEmpty,
    );
  });
}
