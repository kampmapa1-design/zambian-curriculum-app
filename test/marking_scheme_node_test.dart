import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/marking_scheme.dart';
import 'package:zambian_curriculum_app/models/marking_scheme_node.dart';

/// Marking Scheme Structure Stage 1 (2026-09-22) — the tree model, and
/// specifically the real bug pattern it exists to close: a question's own
/// Roman-numeral sub-parts used to look like independent siblings once
/// flattened, letting a section's "answer any N" logic miscount how many
/// real questions were attempted.
void main() {
  group('MarkingSchemeNode — leaf vs computed totals', () {
    test('a leaf reports its own mark; an unset leaf is 0, never a guess', () {
      expect(const MarkingSchemeNode(label: '1', marks: 10).totalMarks, 10);
      expect(const MarkingSchemeNode(label: '1').totalMarks, 0);
      expect(const MarkingSchemeNode(label: '1', marks: 10).isLeaf, isTrue);
    });

    test('a parent node is ALWAYS the sum of its children, never its own stored value', () {
      const question = MarkingSchemeNode(
        label: '2',
        children: [
          MarkingSchemeNode(label: 'a', marks: 4),
          MarkingSchemeNode(label: 'b', marks: 6),
        ],
      );
      expect(question.isLeaf, isFalse);
      expect(question.totalMarks, 10);
    });

    test('three levels deep: Question -> Part -> Sub-part sums correctly at every level', () {
      const question = MarkingSchemeNode(
        label: '3',
        children: [
          MarkingSchemeNode(label: 'a', children: [
            MarkingSchemeNode(label: 'i', marks: 2),
            MarkingSchemeNode(label: 'ii', marks: 3),
          ]),
          MarkingSchemeNode(label: 'b', marks: 5),
        ],
      );
      expect(question.totalMarks, 10); // (2+3) + 5
    });
  });

  group('fullLabel and leaves() — the actual flattening the grading dispatch depends on', () {
    test('a bare top-level question composes to just its own label', () {
      const q = MarkingSchemeNode(label: '1', marks: 10);
      expect(q.fullLabel(null), '1');
    });

    test('Question -> Sub-part directly (no lettered Part layer) composes as "2(i)"', () {
      const question = MarkingSchemeNode(
        label: '2',
        children: [
          MarkingSchemeNode(label: 'i', expectedAnswerOrKeywords: 'x', marks: 5),
          MarkingSchemeNode(label: 'ii', expectedAnswerOrKeywords: 'y', marks: 5),
        ],
      );
      final leaves = question.leaves();
      expect(leaves.map((l) => l.$1), ['2(i)', '2(ii)']);
    });

    test('Question -> Part -> Sub-part composes as "3(a)(i)", nested correctly rather than as siblings', () {
      const question = MarkingSchemeNode(
        label: '3',
        children: [
          MarkingSchemeNode(label: 'a', children: [
            MarkingSchemeNode(label: 'i', marks: 2),
            MarkingSchemeNode(label: 'ii', marks: 3),
          ]),
        ],
      );
      final leaves = question.leaves();
      expect(leaves.map((l) => l.$1), ['3(a)(i)', '3(a)(ii)']);
      // Real regression check: these must nest under Question 3, not read
      // as two independent top-level questions "a(i)"/"a(ii)".
      expect(leaves.every((l) => l.$1.startsWith('3(')), isTrue);
    });
  });

  group('MarkingSchemeSection', () {
    test('totalMarksIfAllAnswered sums every top-level question, sub-parts included', () {
      const section = MarkingSchemeSection(
        name: 'Section B',
        questions: [
          MarkingSchemeNode(label: '1', marks: 20),
          MarkingSchemeNode(label: '2', children: [
            MarkingSchemeNode(label: 'i', marks: 10),
            MarkingSchemeNode(label: 'ii', marks: 10),
          ]),
        ],
      );
      expect(section.totalMarksIfAllAnswered, 40);
    });

    test('flattenedQuestions produces one MarkingSchemeQuestion per real leaf, tagged with this section name', () {
      const section = MarkingSchemeSection(
        name: 'Section A',
        questions: [
          MarkingSchemeNode(label: '1', expectedAnswerOrKeywords: 'ans1', marks: 10),
          MarkingSchemeNode(label: '2', children: [
            MarkingSchemeNode(label: 'a', expectedAnswerOrKeywords: 'ans2a', marks: 5),
            MarkingSchemeNode(label: 'b', expectedAnswerOrKeywords: 'ans2b', marks: 5),
          ]),
        ],
      );
      final flat = section.flattenedQuestions();
      expect(flat.map((q) => q.label), ['1', '2(a)', '2(b)']);
      expect(flat.every((q) => q.sectionName == 'Section A'), isTrue);
      expect(flat.firstWhere((q) => q.label == '2(a)').maxMarks, 5);
      expect(flat.firstWhere((q) => q.label == '2(a)').expectedAnswerOrKeywords, 'ans2a');
    });
  });

  group('MarkingScheme.effectiveQuestions / hasSectionTree — backward compatibility', () {
    test('a scheme with no tree falls back to its original flat questions list, unchanged', () {
      final scheme = MarkingScheme(
        id: 's1',
        title: 'Old Scheme',
        subjectName: 'History',
        gradeName: 'Grade 10',
        topicName: 'x',
        questions: const [
          MarkingSchemeQuestion(label: '1', expectedAnswerOrKeywords: 'a', maxMarks: 10, sectionName: 'Section A'),
        ],
        createdAt: DateTime(2026),
      );
      expect(scheme.hasSectionTree, isFalse);
      expect(scheme.effectiveQuestions, scheme.questions);
      expect(scheme.totalMarks, 10);
    });

    test('a scheme WITH a tree derives effectiveQuestions/totalMarks/sectionNames from it, ignoring the stale flat list', () {
      final scheme = MarkingScheme(
        id: 's2',
        title: 'Tree Scheme',
        subjectName: 'History',
        gradeName: 'Grade 10',
        topicName: 'x',
        questions: const [], // deliberately stale/empty — must be ignored once a tree exists
        createdAt: DateTime(2026),
        sections: const [
          MarkingSchemeSection(name: 'Section A', requiredAnswerCount: 1, questions: [
            MarkingSchemeNode(label: '1', expectedAnswerOrKeywords: 'a', marks: 10),
            MarkingSchemeNode(label: '2', expectedAnswerOrKeywords: 'b', marks: 10),
          ]),
        ],
      );
      expect(scheme.hasSectionTree, isTrue);
      expect(scheme.effectiveQuestions.map((q) => q.label), ['1', '2']);
      expect(scheme.totalMarks, 20);
      expect(scheme.sectionNames, ['Section A']);
    });
  });

  group('withUpdatedLeafMarks — Stage 4\'s one write path', () {
    test('corrects a single leaf deep in the tree, recomputing every ancestor total automatically', () {
      const section = MarkingSchemeSection(
        name: 'Section A',
        questions: [
          MarkingSchemeNode(label: '1', children: [
            MarkingSchemeNode(label: 'a', children: [
              MarkingSchemeNode(label: 'i', marks: 900), // the miskeyed leaf
              MarkingSchemeNode(label: 'ii', marks: 5),
            ]),
          ]),
        ],
      );
      final corrected = section.withUpdatedLeafMarks({'1(a)(i)': 5});
      expect(corrected.totalMarksIfAllAnswered, 10); // 5 + 5, not 905
      expect(section.totalMarksIfAllAnswered, 905, reason: 'the original is untouched — this returns a new tree');
    });

    test('a label not present in the map leaves that leaf untouched', () {
      const section = MarkingSchemeSection(questions: [MarkingSchemeNode(label: '1', marks: 10)], name: 'A');
      final result = section.withUpdatedLeafMarks({'2': 99});
      expect(result.totalMarksIfAllAnswered, 10);
    });
  });

  group('JSON round-trip', () {
    test('a full 3-level tree survives toJson/fromJson exactly', () {
      const original = MarkingSchemeSection(
        name: 'Section C',
        answerInstructions: 'Answer any TWO questions from this section',
        requiredAnswerCount: 2,
        questions: [
          MarkingSchemeNode(label: '1', expectedAnswerOrKeywords: 'x', marks: 10),
          MarkingSchemeNode(label: '2', children: [
            MarkingSchemeNode(label: 'a', children: [
              MarkingSchemeNode(label: 'i', expectedAnswerOrKeywords: 'y', marks: 3),
              MarkingSchemeNode(label: 'ii', expectedAnswerOrKeywords: 'z', marks: 7),
            ]),
          ]),
        ],
      );
      final roundTripped = MarkingSchemeSection.fromJson(original.toJson());
      expect(roundTripped.name, original.name);
      expect(roundTripped.requiredAnswerCount, 2);
      expect(roundTripped.totalMarksIfAllAnswered, original.totalMarksIfAllAnswered);
      expect(
        roundTripped.flattenedQuestions().map((q) => q.label),
        original.flattenedQuestions().map((q) => q.label),
      );
    });
  });
}
