import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/concise_marking_record.dart';
import 'package:zambian_curriculum_app/models/marking_scheme.dart';
import 'package:zambian_curriculum_app/models/marking_script.dart';
import 'package:zambian_curriculum_app/services/question_review_index.dart';

/// Marking Reliability Stage 5: QuestionReviewIndex is the data layer the
/// Stage 6 side-by-side review screen navigates from — these tests are the
/// guarantee that tapping "Q7" really does resolve to Q7's real mark, its
/// real location on the script, and an honest (never invented) key source.
void main() {
  GradedAnswer ans(String label) => GradedAnswer(
        questionLabel: label,
        maxMarks: 10,
        transcribedAnswer: 'an answer',
        marksAwarded: 7,
        confidence: MarkingConfidence.high,
      );

  test('builds one entry per answer, in order, with its mark and location', () {
    final index = QuestionReviewIndex.build(
      answers: [ans('1'), ans('2'), ans('3')],
      annotations: const [
        ScriptAnnotationRecord(questionLabel: '1', pageIndex: 0, yMin: 10, xMin: 10, yMax: 50, xMax: 200),
        ScriptAnnotationRecord(questionLabel: '2'), // no location — the AI wasn't confident
      ],
    );

    expect(index.orderedLabels, ['1', '2', '3']);
    expect(index.length, 3);
    expect(index['1']!.hasScriptLocation, isTrue);
    expect(index['1']!.scriptLocation!.pageIndex, 0);
    expect(index['2']!.hasScriptLocation, isFalse, reason: 'a record with no coordinates is not a real location');
    expect(index['3']!.scriptLocation, isNull, reason: 'no annotation at all for this question');
    expect(index['1']!.answer!.marksAwarded, 7);
  });

  test('indexed access by position matches indexed access by label', () {
    final index = QuestionReviewIndex.build(answers: [ans('1'), ans('2')]);
    expect(index.entryAt(0), index['1']);
    expect(index.entryAt(1), index['2']);
    expect(index.entryAt(2), isNull);
    expect(index.indexOfLabel('2'), 1);
    expect(index.indexOfLabel('nope'), -1);
  });

  test('a question with a keyed marking scheme entry uses the scheme\'s own expected-answer text', () {
    final scheme = MarkingScheme(
      id: 's1', title: 'x', subjectName: 'History', gradeName: 'Grade 10', topicName: 'x',
      questions: const [MarkingSchemeQuestion(label: '1', expectedAnswerOrKeywords: 'Shaka Zulu united the clans', maxMarks: 10)],
      createdAt: DateTime(2026),
    );
    final index = QuestionReviewIndex.build(answers: [ans('1')], scheme: scheme);
    final source = index['1']!.keySource;
    expect(source.kind, QuestionKeySourceKind.schemeText);
    expect(source.expectedAnswerText, 'Shaka Zulu united the clans');
  });

  test('a scheme question with BLANK expected-answer text does not count as a real key source', () {
    final scheme = MarkingScheme(
      id: 's1', title: 'x', subjectName: 'History', gradeName: 'Grade 10', topicName: 'x',
      questions: const [MarkingSchemeQuestion(label: '1', expectedAnswerOrKeywords: '   ', maxMarks: 10)],
      createdAt: DateTime(2026),
    );
    final index = QuestionReviewIndex.build(answers: [ans('1')], scheme: scheme, questionPaperImageCount: 1);
    // Falls through to the next real source instead of an empty "expected answer".
    expect(index['1']!.keySource.kind, QuestionKeySourceKind.questionPaperImage);
  });

  test('no scheme, exactly ONE question-paper image: every question defaults to it', () {
    final index = QuestionReviewIndex.build(answers: [ans('1'), ans('2')], questionPaperImageCount: 1);
    for (final label in ['1', '2']) {
      final source = index[label]!.keySource;
      expect(source.kind, QuestionKeySourceKind.questionPaperImage);
      expect(source.imageIndex, 0);
    }
  });

  test('MULTIPLE question-paper images: the source is known to exist, but the specific page is honestly unknown', () {
    final index = QuestionReviewIndex.build(answers: [ans('1')], questionPaperImageCount: 3);
    final source = index['1']!.keySource;
    expect(source.kind, QuestionKeySourceKind.questionPaperImage);
    expect(source.imageIndex, isNull, reason: 'never guess which of several pages holds this question');
  });

  test('pure-AI marking with no question paper attached at all: no key source, never invented', () {
    final index = QuestionReviewIndex.build(answers: [ans('1')]);
    expect(index['1']!.keySource.kind, QuestionKeySourceKind.none);
  });

  test('a keyed scheme still wins over an attached question-paper image for a question it actually covers', () {
    final scheme = MarkingScheme(
      id: 's1', title: 'x', subjectName: 'History', gradeName: 'Grade 10', topicName: 'x',
      questions: const [MarkingSchemeQuestion(label: '1', expectedAnswerOrKeywords: 'real answer', maxMarks: 10)],
      createdAt: DateTime(2026),
    );
    final index = QuestionReviewIndex.build(answers: [ans('1'), ans('2')], scheme: scheme, questionPaperImageCount: 1);
    expect(index['1']!.keySource.kind, QuestionKeySourceKind.schemeText, reason: 'the scheme actually covers Q1');
    expect(index['2']!.keySource.kind, QuestionKeySourceKind.questionPaperImage, reason: 'Q2 has no scheme entry — falls back to the question paper');
  });

  test('a duplicate question label in the answers list is only indexed once', () {
    final index = QuestionReviewIndex.build(answers: [ans('1'), ans('1')]);
    expect(index.orderedLabels, ['1']);
  });

  test('empty input is a real, safe empty index, not null or an error', () {
    final index = QuestionReviewIndex.build(answers: const []);
    expect(index.isEmpty, isTrue);
    expect(index.entryAt(0), isNull);
    expect(QuestionReviewIndex.empty.isEmpty, isTrue);
  });
}
