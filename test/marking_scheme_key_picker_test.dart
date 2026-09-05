// Regression test (2026-09-05) for a real reported bug: two genuinely
// saved marking keys ("History Paper 1", "History Paper 2" -- reasonable
// free-typed subject names for two different real exam papers of the
// bundled "History" syllabus subject) were completely hidden from the
// "start a new marking cohort" picker because neither name matched the
// bundled subject's own name EXACTLY, and the app wrongly reported "no
// marking key uploaded" despite both being safely saved.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/marking_scheme.dart';
import 'package:zambian_curriculum_app/services/marking_scheme_key_picker.dart';

MarkingScheme _scheme(String subjectName, String title, {DateTime? createdAt}) => MarkingScheme(
      id: '$subjectName-$title',
      title: title,
      subjectName: subjectName,
      gradeName: 'Grade 12',
      topicName: 'Mock Exam',
      questions: const [MarkingSchemeQuestion(label: 'Q1', expectedAnswerOrKeywords: 'x', maxMarks: 10)],
      createdAt: createdAt ?? DateTime(2026, 9, 5),
    );

void main() {
  test('a differently-worded subject name is never hidden -- it lands in "other", not dropped', () {
    final paper1 = _scheme('History Paper 1', 'History P1 Mock');
    final paper2 = _scheme('History Paper 2', 'History P2 Mock');
    final result = splitMarkingSchemesBySubjectMatch([paper1, paper2], 'History');

    // The real reported bug: this used to be empty, reporting "no
    // marking key uploaded" for a subject that genuinely had two.
    expect(result.matching, isEmpty);
    expect(result.other, containsAll([paper1, paper2]));
    expect(result.other.length, 2);
  });

  test('an exact (case/whitespace-insensitive) subject match is surfaced first, under "matching"', () {
    final history = _scheme('history', 'Plain History Key'); // lowercase, real teacher input varies
    final geography = _scheme('Geography', 'Geography Key');
    final result = splitMarkingSchemesBySubjectMatch([history, geography], '  History  ');

    expect(result.matching, [history]);
    expect(result.other, [geography]);
  });

  test('both lists are newest-first', () {
    final older = _scheme('History', 'Older', createdAt: DateTime(2026, 1, 1));
    final newer = _scheme('History', 'Newer', createdAt: DateTime(2026, 9, 1));
    final result = splitMarkingSchemesBySubjectMatch([older, newer], 'History');
    expect(result.matching, [newer, older]);
  });

  test('nothing saved yet -- both lists empty, not an error', () {
    final result = splitMarkingSchemesBySubjectMatch([], 'History');
    expect(result.matching, isEmpty);
    expect(result.other, isEmpty);
  });
}
