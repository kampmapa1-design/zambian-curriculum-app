import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import '../models/marking_scheme.dart';
import '../models/marking_script.dart' show MarkingConfidence;

enum HomeAssignmentPageLength {
  one,
  two;

  String get wireValue => name;
  String get label => switch (this) {
        HomeAssignmentPageLength.one => 'One page',
        HomeAssignmentPageLength.two => 'Two pages',
      };
}

enum HomeAssignmentQuestionType {
  summative,
  formative;

  String get wireValue => name;
  String get label => switch (this) {
        HomeAssignmentQuestionType.summative => 'Summative',
        HomeAssignmentQuestionType.formative => 'Formative',
      };
}

/// One question as a learner would see it — Home Assignment epic, Stage
/// 5. Mirrors [MarkingSchemeQuestion]'s shape closely (same `number`/
/// `label` and `maxMarks`) since the two are generated together and the
/// marking key is built directly from these plus the AI's matching
/// answer-key entries (see [HomeAssignmentResult.toMarkingSchemeQuestions]).
class HomeAssignmentQuestion {
  final String number;
  final String text;
  final double maxMarks;

  const HomeAssignmentQuestion({required this.number, required this.text, required this.maxMarks});

  factory HomeAssignmentQuestion.fromMap(Map<Object?, Object?> map) => HomeAssignmentQuestion(
        number: map['number'] as String? ?? '',
        text: map['text'] as String? ?? '',
        maxMarks: (map['maxMarks'] as num?)?.toDouble() ?? 0,
      );
}

class HomeAssignmentKeyEntry {
  final String number;
  final String expectedAnswerOrKeywords;

  const HomeAssignmentKeyEntry({required this.number, required this.expectedAnswerOrKeywords});

  factory HomeAssignmentKeyEntry.fromMap(Map<Object?, Object?> map) => HomeAssignmentKeyEntry(
        number: map['number'] as String? ?? '',
        expectedAnswerOrKeywords: map['expectedAnswerOrKeywords'] as String? ?? '',
      );
}

/// The full result of `generateHomeAssignment` — Home Assignment epic,
/// Stages 5 & 6. Never auto-applied anywhere: the questions are shown for
/// the teacher's own review before sending, and [toMarkingSchemeQuestions]
/// only ever feeds MarkingSchemeBuilderScreen as a draft, never saves
/// directly (see that screen's own "sole persistence path" rule).
class HomeAssignmentResult {
  final String title;
  final String instructions;
  final List<HomeAssignmentQuestion> questions;
  final List<HomeAssignmentKeyEntry> markingKey;
  final String notes;

  const HomeAssignmentResult({
    required this.title,
    required this.instructions,
    required this.questions,
    required this.markingKey,
    required this.notes,
  });

  factory HomeAssignmentResult.fromMap(Map<Object?, Object?> map) => HomeAssignmentResult(
        title: map['title'] as String? ?? 'Home Assignment',
        instructions: map['instructions'] as String? ?? '',
        questions: ((map['questions'] as List?) ?? const [])
            .map((q) => HomeAssignmentQuestion.fromMap(q as Map<Object?, Object?>))
            .toList(),
        markingKey: ((map['markingKey'] as List?) ?? const [])
            .map((k) => HomeAssignmentKeyEntry.fromMap(k as Map<Object?, Object?>))
            .toList(),
        notes: map['notes'] as String? ?? '',
      );

  /// Joins [questions] to [markingKey] by `number` — a question with no
  /// matching key entry (shouldn't happen per the prompt's own
  /// instruction, but AI output is never fully trusted) gets an empty
  /// expected answer rather than being silently dropped, so the teacher
  /// sees it as an empty field to fill in during review, not a missing
  /// question.
  List<MarkingSchemeQuestion> toMarkingSchemeQuestions() {
    final byNumber = {for (final k in markingKey) k.number: k.expectedAnswerOrKeywords};
    return [
      for (final q in questions)
        MarkingSchemeQuestion(
          label: 'Q${q.number}: ${q.text}',
          expectedAnswerOrKeywords: byNumber[q.number] ?? '',
          maxMarks: q.maxMarks,
        ),
    ];
  }

  double get totalMarks => questions.fold(0, (sum, q) => sum + q.maxMarks);
}

/// Home Assignment epic, Stage 7 — one ISSUED assignment, as stored at
/// `schools/{schoolId}/classes/{classId}/homeAssignments/{id}` (written
/// only by `sendHomeAssignmentToClass`). Distinct from
/// [HomeAssignmentResult]: that's the freshly-generated draft before a
/// teacher has chosen to send anything; this is what's actually live for
/// a class, readable by every learner linked to it.
class IssuedHomeAssignment {
  final String id;
  final String title;
  final String instructions;
  final String subjectName;
  final String className;
  final List<HomeAssignmentQuestion> questions;
  final String markingKeyTitle;
  final List<HomeAssignmentKeyEntry> markingKey;
  final String subjectTeacherUid;
  final String subjectTeacherName;
  final DateTime? createdAt;
  final DateTime? deadline;

  /// The short "HA-MATH-240912-A3"-style code embedded in every email
  /// subject/WhatsApp message for this assignment (2026-09-16, per
  /// explicit request) — how a reply gets matched back to it, whichever
  /// ingestion path the reply eventually arrives through. Null only for
  /// an assignment sent before this field existed.
  final String? referenceCode;

  const IssuedHomeAssignment({
    required this.id,
    required this.title,
    required this.instructions,
    required this.subjectName,
    required this.className,
    required this.questions,
    required this.markingKeyTitle,
    required this.markingKey,
    required this.subjectTeacherUid,
    required this.subjectTeacherName,
    required this.createdAt,
    required this.deadline,
    this.referenceCode,
  });

  factory IssuedHomeAssignment.fromMap(String id, Map<String, dynamic> data) => IssuedHomeAssignment(
        id: id,
        title: data['title'] as String? ?? '',
        instructions: data['instructions'] as String? ?? '',
        subjectName: data['subjectName'] as String? ?? '',
        className: data['className'] as String? ?? '',
        questions: ((data['questions'] as List?) ?? const [])
            .map((q) => HomeAssignmentQuestion.fromMap((q as Map).cast<Object?, Object?>()))
            .toList(),
        markingKeyTitle: data['markingKeyTitle'] as String? ?? '',
        markingKey: ((data['markingKey'] as List?) ?? const [])
            .map((k) => HomeAssignmentKeyEntry.fromMap((k as Map).cast<Object?, Object?>()))
            .toList(),
        subjectTeacherUid: data['subjectTeacherUid'] as String? ?? '',
        subjectTeacherName: data['subjectTeacherName'] as String? ?? '',
        createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
        deadline: data['deadlineIso'] != null ? DateTime.tryParse(data['deadlineIso'] as String) : null,
        referenceCode: data['referenceCode'] as String?,
      );

  double get totalMarks => questions.fold(0, (sum, q) => sum + q.maxMarks);

  List<MarkingSchemeQuestion> toMarkingSchemeQuestions() {
    final byNumber = {for (final k in markingKey) k.number: k.expectedAnswerOrKeywords};
    return [
      for (final q in questions)
        MarkingSchemeQuestion(label: 'Q${q.number}: ${q.text}', expectedAnswerOrKeywords: byNumber[q.number] ?? '', maxMarks: q.maxMarks),
    ];
  }
}

enum HomeAssignmentSubmissionStatus {
  queued,
  marked,
  sent;

  static HomeAssignmentSubmissionStatus fromWire(String? value) => switch (value) {
        'marked' => HomeAssignmentSubmissionStatus.marked,
        'sent' => HomeAssignmentSubmissionStatus.sent,
        _ => HomeAssignmentSubmissionStatus.queued,
      };
}

/// One learner's submitted answer photos + (once marked) their result —
/// Home Assignment epic, Stages 8-11.
class HomeAssignmentSubmission {
  final String id;
  final String learnerName;
  final List<String> photoPaths;
  final String submittedVia; // 'app' | 'imported'
  final DateTime? submittedAt;
  final HomeAssignmentSubmissionStatus status;
  final double? score;
  final double? maxScore;
  final String? markingEngine; // 'concise' | 'stable'
  final List<MarkingConfidence> answerConfidences;

  const HomeAssignmentSubmission({
    required this.id,
    required this.learnerName,
    required this.photoPaths,
    required this.submittedVia,
    required this.submittedAt,
    required this.status,
    required this.score,
    required this.maxScore,
    required this.markingEngine,
    required this.answerConfidences,
  });

  factory HomeAssignmentSubmission.fromMap(String id, Map<String, dynamic> data) => HomeAssignmentSubmission(
        id: id,
        learnerName: data['learnerName'] as String? ?? '',
        photoPaths: (data['photoPaths'] as List?)?.whereType<String>().toList() ?? const [],
        submittedVia: data['submittedVia'] as String? ?? 'app',
        submittedAt: (data['submittedAt'] as Timestamp?)?.toDate(),
        status: HomeAssignmentSubmissionStatus.fromWire(data['status'] as String?),
        score: (data['score'] as num?)?.toDouble(),
        maxScore: (data['maxScore'] as num?)?.toDouble(),
        markingEngine: data['markingEngine'] as String?,
        answerConfidences: ((data['answers'] as List?) ?? const [])
            .map((a) => MarkingConfidence.fromValue((a as Map)['confidence'] as String? ?? 'low'))
            .toList(),
      );

  bool get hasLowConfidence => answerConfidences.any((c) => c != MarkingConfidence.high);
}
