import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import 'marking_scheme_repository.dart';

/// One question's outcome in a gap report — whether the marking key's
/// ideal answer was found in the student's script or not, derived
/// directly from the marks already awarded during grading. Deliberately
/// NOT a new AI call: the grading pipeline (Stage 4) already transcribes
/// and compares each answer against the scheme, so this is a simple,
/// fully offline, zero-additional-cost derivation from data the app
/// already has — more reliable than asking the AI to judge the same
/// thing twice.
class GapReportQuestionOutcome {
  final String questionLabel;
  final String expectedAnswer;
  final String studentAnswer;
  final double marksAwarded;
  final double maxMarks;
  final bool present;

  const GapReportQuestionOutcome({
    required this.questionLabel,
    required this.expectedAnswer,
    required this.studentAnswer,
    required this.marksAwarded,
    required this.maxMarks,
    required this.present,
  });
}

/// "Report on [student name]" — the simple present/missing comparison
/// against the marking key's ideal answers, requested as a companion to
/// (not a replacement for) the existing per-question marks/confidence
/// grading already produced by MarkingGradingService.
class MarkingGapReport {
  final String studentName;
  final String subjectName;
  final String gradeName;
  final List<GapReportQuestionOutcome> present;
  final List<GapReportQuestionOutcome> missing;

  const MarkingGapReport({
    required this.studentName,
    required this.subjectName,
    required this.gradeName,
    required this.present,
    required this.missing,
  });
}

/// Thrown when a report can't be built — the script hasn't actually been
/// graded yet, or its linked marking scheme can't be found.
class MarkingGapReportUnavailable implements Exception {
  final String message;
  const MarkingGapReportUnavailable(this.message);
  @override
  String toString() => message;
}

class MarkingGapReportService {
  MarkingGapReportService({MarkingSchemeRepository? schemeRepository})
      : _schemeRepository = schemeRepository ?? MarkingSchemeRepository();

  final MarkingSchemeRepository _schemeRepository;

  Future<MarkingGapReport> build(MarkingScript script) async {
    final answers = script.gradedAnswers;
    if (answers == null || answers.isEmpty) {
      throw const MarkingGapReportUnavailable('This script has not been graded yet.');
    }

    Map<String, MarkingSchemeQuestion> expectedByLabel = const {};
    final schemeId = script.schemeId;
    if (schemeId != null) {
      final catalog = await _schemeRepository.loadCatalog();
      MarkingScheme? scheme;
      for (final s in catalog.schemes) {
        if (s.id == schemeId) {
          scheme = s;
          break;
        }
      }
      if (scheme != null) {
        expectedByLabel = {for (final q in scheme.questions) q.label: q};
      }
    }

    final present = <GapReportQuestionOutcome>[];
    final missing = <GapReportQuestionOutcome>[];
    for (final a in answers) {
      final expected = expectedByLabel[a.questionLabel]?.expectedAnswerOrKeywords ?? '(marking scheme unavailable)';
      final blank = a.transcribedAnswer.trim().isEmpty ||
          a.transcribedAnswer.toLowerCase().contains('no answer') ||
          a.transcribedAnswer.toLowerCase().contains('illegible');
      final isPresent = a.marksAwarded > 0 && !blank;
      final outcome = GapReportQuestionOutcome(
        questionLabel: a.questionLabel,
        expectedAnswer: expected,
        studentAnswer: a.transcribedAnswer,
        marksAwarded: a.marksAwarded,
        maxMarks: a.maxMarks,
        present: isPresent,
      );
      (isPresent ? present : missing).add(outcome);
    }

    return MarkingGapReport(
      studentName: '${script.firstName} ${script.surname}'.trim(),
      subjectName: script.subjectName,
      gradeName: script.gradeName,
      present: present,
      missing: missing,
    );
  }
}
