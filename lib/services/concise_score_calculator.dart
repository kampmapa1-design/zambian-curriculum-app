import '../models/marking_rubric.dart';
import '../models/marking_script.dart';

/// One section's contribution to a Concise Marking score.
class SectionScore {
  final String name;

  /// Marks the candidate earned for this section, already scaled to the
  /// section's own paper allocation where the rubric gives one.
  final double awarded;

  /// What this section is worth — the rubric's stated allocation when it
  /// has one, otherwise the sum of the counted questions' own max marks.
  final double possible;

  /// How many questions in this section were actually counted toward the
  /// total (the required number, per the rubric's "answer N of M").
  final int countedQuestions;

  /// How many extra attempts in this section were ignored because the
  /// candidate answered more than the rules required — per the explicit
  /// request: "do not add to the total all the other questions in that
  /// section". The candidate's best-scoring required number is kept.
  final int ignoredExcessQuestions;

  final List<String> countedLabels;
  final List<String> ignoredLabels;

  const SectionScore({
    required this.name,
    required this.awarded,
    required this.possible,
    required this.countedQuestions,
    required this.ignoredExcessQuestions,
    required this.countedLabels,
    required this.ignoredLabels,
  });

  double get percentage => possible <= 0 ? 0 : (awarded / possible) * 100;
}

/// The whole-script Concise Marking result — everything normalised so a
/// completed paper "adds up to only 100 marks or 100 percent when the
/// stipulated total number of questions per section per script are marked"
/// (explicit request, 2026-09-10).
class ConciseScore {
  final List<SectionScore> sections;

  /// Raw marks earned across all counted questions, before the final
  /// out-of-100 normalisation.
  final double awardedMarks;

  /// Raw marks available across all counted questions (or the paper's
  /// stated total when it gives one).
  final double possibleMarks;

  /// The headline figure: [awardedMarks] as a percentage of
  /// [possibleMarks], i.e. the score out of 100.
  final double percentage;

  /// True when a rubric was available and used to apply "answer N of M"
  /// / section-allocation rules. False means this is a plain sum of every
  /// graded answer (no cover-page rules were found) — still valid, just
  /// not section-aware.
  final bool rubricApplied;

  const ConciseScore({
    required this.sections,
    required this.awardedMarks,
    required this.possibleMarks,
    required this.percentage,
    required this.rubricApplied,
  });

  static String fmt(double n) =>
      n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);

  /// "73 / 100" — the out-of-100 score to stamp on page 1.
  String get outOf100Label => '${fmt(percentage.clamp(0, 100))} / 100';

  /// "58 / 80" — the raw marks, for the report body.
  String get rawFractionLabel => '${fmt(awardedMarks)} / ${fmt(possibleMarks)}';

  int get roundedPercent => percentage.clamp(0, 100).round();
}

/// Deterministic, offline scoring for Concise Marking. The AI grades and
/// locates each answer; THIS class alone decides the total — so the
/// "everything adds up to 100" guarantee never depends on the model doing
/// arithmetic. Fail-proof by construction: with no rubric it degrades to
/// a plain percentage of every graded answer.
class ConciseScoreCalculator {
  const ConciseScoreCalculator();

  static const _noSectionKey = '(no section)';

  ConciseScore compute({
    required List<GradedAnswer> answers,
    required Map<String, String?> sectionByLabel,
    MarkingRubric? rubric,
  }) {
    // Group answers by section, preserving first-appearance order.
    final order = <String>[];
    final grouped = <String, List<GradedAnswer>>{};
    for (final a in answers) {
      final raw = sectionByLabel[a.questionLabel]?.trim();
      final key = (raw == null || raw.isEmpty) ? _noSectionKey : raw;
      if (!grouped.containsKey(key)) {
        grouped[key] = [];
        order.add(key);
      }
      grouped[key]!.add(a);
    }

    final rubricApplied = rubric != null && !rubric.isEmpty;
    final sectionScores = <SectionScore>[];

    for (final key in order) {
      final sectionAnswers = grouped[key]!;
      final displayName = key == _noSectionKey ? 'All questions' : key;
      final required = key == _noSectionKey ? null : rubric?.requiredCountFor(key);

      List<GradedAnswer> counted;
      List<GradedAnswer> ignored;
      if (required != null && required > 0 && required < sectionAnswers.length) {
        // Keep the candidate's best-scoring `required` attempts.
        final ranked = [...sectionAnswers]..sort(_bestFirst);
        counted = ranked.take(required).toList();
        ignored = ranked.skip(required).toList();
      } else {
        counted = sectionAnswers;
        ignored = const [];
      }

      final rawAwarded = counted.fold<double>(0, (s, a) => s + a.marksAwarded);
      final rawPossible = counted.fold<double>(0, (s, a) => s + a.maxMarks);

      final allocated = key == _noSectionKey ? null : rubric?.allocatedMarksFor(key);
      final double possible;
      final double awarded;
      if (allocated != null && allocated > 0 && rawPossible > 0) {
        possible = allocated;
        awarded = (rawAwarded / rawPossible) * allocated;
      } else {
        possible = rawPossible;
        awarded = rawAwarded;
      }

      sectionScores.add(SectionScore(
        name: displayName,
        awarded: awarded,
        possible: possible,
        countedQuestions: counted.length,
        ignoredExcessQuestions: ignored.length,
        countedLabels: [for (final a in counted) a.questionLabel],
        ignoredLabels: [for (final a in ignored) a.questionLabel],
      ));
    }

    var totalAwarded = sectionScores.fold<double>(0, (s, sec) => s + sec.awarded);
    var totalPossible = sectionScores.fold<double>(0, (s, sec) => s + sec.possible);

    // If the paper states its own grand total and it disagrees with the
    // section sum, the paper wins — scale to it.
    final paperTotal = rubric?.paperTotalMarks;
    if (paperTotal != null && paperTotal > 0 && totalPossible > 0 && (paperTotal - totalPossible).abs() > 0.01) {
      totalAwarded = (totalAwarded / totalPossible) * paperTotal;
      totalPossible = paperTotal;
    }

    final percentage = totalPossible <= 0 ? 0.0 : (totalAwarded / totalPossible) * 100;

    return ConciseScore(
      sections: sectionScores,
      awardedMarks: totalAwarded,
      possibleMarks: totalPossible,
      percentage: percentage,
      rubricApplied: rubricApplied,
    );
  }

  /// Higher raw mark first; then higher proportion of the question's own
  /// maximum; then leave the original order alone.
  int _bestFirst(GradedAnswer a, GradedAnswer b) {
    final byMark = b.marksAwarded.compareTo(a.marksAwarded);
    if (byMark != 0) return byMark;
    final ra = a.maxMarks <= 0 ? 0.0 : a.marksAwarded / a.maxMarks;
    final rb = b.maxMarks <= 0 ? 0.0 : b.marksAwarded / b.maxMarks;
    return rb.compareTo(ra);
  }
}
