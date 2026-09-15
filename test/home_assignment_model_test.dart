import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/home_assignment.dart';
import 'package:zambian_curriculum_app/models/marking_script.dart';

/// Home Assignment epic, Stages 5-11 — real regression coverage for the
/// pure joining/parsing logic in the model layer, none of which had any
/// automated test despite being exactly the kind of "AI returned
/// something slightly malformed" edge case that's easy to get wrong
/// silently (a dropped question, a mismatched marking-key number).
void main() {
  group('HomeAssignmentResult.toMarkingSchemeQuestions', () {
    test('joins each question to its matching marking-key entry by number', () {
      const result = HomeAssignmentResult(
        title: 'Fractions Practice',
        instructions: 'Answer all questions.',
        questions: [
          HomeAssignmentQuestion(number: '1', text: 'What is 1/2 + 1/4?', maxMarks: 2),
          HomeAssignmentQuestion(number: '2', text: 'Simplify 6/8.', maxMarks: 3),
        ],
        markingKey: [
          HomeAssignmentKeyEntry(number: '1', expectedAnswerOrKeywords: '3/4'),
          HomeAssignmentKeyEntry(number: '2', expectedAnswerOrKeywords: '3/4'),
        ],
        notes: '',
      );
      final questions = result.toMarkingSchemeQuestions();
      expect(questions, hasLength(2));
      expect(questions[0].label, 'Q1: What is 1/2 + 1/4?');
      expect(questions[0].expectedAnswerOrKeywords, '3/4');
      expect(questions[0].maxMarks, 2);
      expect(questions[1].maxMarks, 3);
    });

    test('a question with no matching key entry (AI dropped one) gets an empty expected answer, not dropped from the list', () {
      const result = HomeAssignmentResult(
        title: 'Test',
        instructions: '',
        questions: [
          HomeAssignmentQuestion(number: '1', text: 'Q one', maxMarks: 1),
          HomeAssignmentQuestion(number: '2', text: 'Q two', maxMarks: 1),
        ],
        markingKey: [
          HomeAssignmentKeyEntry(number: '1', expectedAnswerOrKeywords: 'answer one'),
          // no entry for question 2 — simulates a malformed AI response
        ],
        notes: '',
      );
      final questions = result.toMarkingSchemeQuestions();
      expect(questions, hasLength(2), reason: 'every question must survive the join, even an unmatched one — never silently dropped');
      expect(questions[1].expectedAnswerOrKeywords, isEmpty);
    });

    test('totalMarks sums every question\'s maxMarks', () {
      const result = HomeAssignmentResult(
        title: 'Test',
        instructions: '',
        questions: [
          HomeAssignmentQuestion(number: '1', text: 'a', maxMarks: 2),
          HomeAssignmentQuestion(number: '2', text: 'b', maxMarks: 3.5),
        ],
        markingKey: [],
        notes: '',
      );
      expect(result.totalMarks, 5.5);
    });
  });

  group('HomeAssignmentResult.fromMap defensive parsing', () {
    test('missing fields fall back to safe defaults instead of throwing', () {
      final result = HomeAssignmentResult.fromMap(const {});
      expect(result.title, 'Home Assignment');
      expect(result.questions, isEmpty);
      expect(result.markingKey, isEmpty);
      expect(result.notes, '');
    });
  });

  group('IssuedHomeAssignment.fromMap', () {
    test('parses a well-formed document', () {
      final assignment = IssuedHomeAssignment.fromMap('a1', {
        'title': 'Fractions Practice',
        'instructions': 'Do it neatly.',
        'subjectName': 'Mathematics',
        'className': 'Grade 8A',
        'questions': [
          {'number': '1', 'text': 'Q1', 'maxMarks': 2},
        ],
        'markingKeyTitle': 'Marking Key — Home Assignment — Mathematics — Fractions',
        'markingKey': [
          {'number': '1', 'expectedAnswerOrKeywords': '3/4'},
        ],
        'subjectTeacherUid': 'uid1',
        'subjectTeacherName': 'Mrs Banda',
        'deadlineIso': null,
      });
      expect(assignment.id, 'a1');
      expect(assignment.title, 'Fractions Practice');
      expect(assignment.questions, hasLength(1));
      expect(assignment.totalMarks, 2);
      expect(assignment.deadline, isNull);
    });

    test('a missing/unparseable deadlineIso never throws — deadline just comes back null', () {
      final assignment = IssuedHomeAssignment.fromMap('a1', {'deadlineIso': 'not-a-real-date'});
      expect(assignment.deadline, isNull);
    });

    test('an empty document parses to empty/default fields, never throws', () {
      final assignment = IssuedHomeAssignment.fromMap('a1', {});
      expect(assignment.title, '');
      expect(assignment.questions, isEmpty);
      expect(assignment.totalMarks, 0);
    });
  });

  group('HomeAssignmentSubmission', () {
    test('hasLowConfidence is true if ANY answer is medium or low confidence', () {
      final submission = HomeAssignmentSubmission.fromMap('s1', {
        'learnerName': 'Chanda',
        'answers': [
          {'confidence': 'high'},
          {'confidence': 'low'},
        ],
      });
      expect(submission.hasLowConfidence, isTrue);
    });

    test('hasLowConfidence is false only when every answer is high confidence', () {
      final submission = HomeAssignmentSubmission.fromMap('s1', {
        'learnerName': 'Chanda',
        'answers': [
          {'confidence': 'high'},
          {'confidence': 'high'},
        ],
      });
      expect(submission.hasLowConfidence, isFalse);
    });

    test('no answers at all -> hasLowConfidence is false (nothing to flag)', () {
      final submission = HomeAssignmentSubmission.fromMap('s1', {'learnerName': 'Chanda'});
      expect(submission.answerConfidences, isEmpty);
      expect(submission.hasLowConfidence, isFalse);
    });

    test('an unrecognized confidence string defaults to low (fail safe toward flagging, not hiding)', () {
      final submission = HomeAssignmentSubmission.fromMap('s1', {
        'learnerName': 'Chanda',
        'answers': [
          {'confidence': 'not-a-real-value'},
        ],
      });
      expect(submission.answerConfidences.single, MarkingConfidence.low);
      expect(submission.hasLowConfidence, isTrue);
    });

    test('status defaults to queued for a document with no status field', () {
      final submission = HomeAssignmentSubmission.fromMap('s1', {'learnerName': 'Chanda'});
      expect(submission.status, HomeAssignmentSubmissionStatus.queued);
    });
  });
}
