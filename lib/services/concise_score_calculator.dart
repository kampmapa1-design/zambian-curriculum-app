import '../models/marking_rubric.dart';
import '../models/marking_scheme_node.dart';
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

  Map<String, dynamic> toJson() => {
        'name': name,
        'awarded': awarded,
        'possible': possible,
        'countedQuestions': countedQuestions,
        'ignoredExcessQuestions': ignoredExcessQuestions,
        'countedLabels': countedLabels,
        'ignoredLabels': ignoredLabels,
      };

  factory SectionScore.fromJson(Map<String, dynamic> json) => SectionScore(
        name: json['name'] as String? ?? '',
        awarded: (json['awarded'] as num?)?.toDouble() ?? 0,
        possible: (json['possible'] as num?)?.toDouble() ?? 0,
        countedQuestions: (json['countedQuestions'] as num?)?.toInt() ?? 0,
        ignoredExcessQuestions: (json['ignoredExcessQuestions'] as num?)?.toInt() ?? 0,
        countedLabels: (json['countedLabels'] as List?)?.cast<String>() ?? const [],
        ignoredLabels: (json['ignoredLabels'] as List?)?.cast<String>() ?? const [],
      );
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

  /// Hard sanity-check safeguard (added 2026-09-22, after a real incident
  /// where a single miskeyed/misread mark on a History paper produced an
  /// out-of-range "900 / 100" result that was shown to a teacher as if it
  /// were a real score). True when this computation failed its own
  /// internal bounds check — see [ConciseScoreCalculator.kToleranceFraction]
  /// — and must NOT be trusted, displayed as a normal grade, or fed into
  /// any average. [sections] is still populated with whatever was computed
  /// (the raw section-by-section breakdown), so a teacher can see exactly
  /// where it went wrong; [awardedMarks]/[possibleMarks]/[percentage] are
  /// NOT meaningful when this is true.
  final bool structureError;

  /// Plain-language explanation of what looked wrong, naming the specific
  /// question(s) when the calculator could identify a likely culprit. Null
  /// unless [structureError] is true.
  final String? structureErrorReason;

  const ConciseScore({
    required this.sections,
    required this.awardedMarks,
    required this.possibleMarks,
    required this.percentage,
    required this.rubricApplied,
    this.structureError = false,
    this.structureErrorReason,
  });

  static String fmt(double n) =>
      n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);

  /// "73 / 100" — the out-of-100 score to stamp on page 1. Returns a safe
  /// placeholder instead of a number when [structureError] is true — this
  /// getter is the defence-in-depth: any caller that forgets to check the
  /// flag explicitly still can never display an out-of-range score.
  String get outOf100Label => structureError ? 'Needs review' : '${fmt(percentage.clamp(0, 100))} / 100';

  /// "58 / 80" — the raw marks, for the report body. Same safe-placeholder
  /// behaviour as [outOf100Label] — see that getter's doc comment.
  String get rawFractionLabel => structureError ? 'Needs review' : '${fmt(awardedMarks)} / ${fmt(possibleMarks)}';

  /// Never a real number when [structureError] — 0, NOT the true (possibly
  /// huge or negative) figure, so an average built from this can never be
  /// blown up by an unreviewed script. A caller building a class average
  /// should still prefer to EXCLUDE a structure-error script entirely
  /// rather than average it in as a 0 — this is the safe fallback for a
  /// caller that doesn't do that exclusion.
  int get roundedPercent => structureError ? 0 : percentage.clamp(0, 100).round();

  Map<String, dynamic> toJson() => {
        'sections': [for (final s in sections) s.toJson()],
        'awardedMarks': awardedMarks,
        'possibleMarks': possibleMarks,
        'percentage': percentage,
        'rubricApplied': rubricApplied,
        if (structureError) 'structureError': true,
        if (structureErrorReason != null) 'structureErrorReason': structureErrorReason,
      };

  factory ConciseScore.fromJson(Map<String, dynamic> json) => ConciseScore(
        sections: (json['sections'] as List?)
                ?.whereType<Map>()
                .map((m) => SectionScore.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
        awardedMarks: (json['awardedMarks'] as num?)?.toDouble() ?? 0,
        possibleMarks: (json['possibleMarks'] as num?)?.toDouble() ?? 0,
        percentage: (json['percentage'] as num?)?.toDouble() ?? 0,
        rubricApplied: json['rubricApplied'] as bool? ?? false,
        structureError: json['structureError'] as bool? ?? false,
        structureErrorReason: json['structureErrorReason'] as String?,
      );
}

/// Deterministic, offline scoring for Concise Marking. The AI grades and
/// locates each answer; THIS class alone decides the total — so the
/// "everything adds up to 100" guarantee never depends on the model doing
/// arithmetic. Fail-proof by construction: with no rubric it degrades to
/// a plain percentage of every graded answer.
class ConciseScoreCalculator {
  const ConciseScoreCalculator();

  static const _noSectionKey = '(no section)';

  /// How far the final total may exceed the paper's own possible marks
  /// before the calculator refuses to output it (Stage 2 safeguard, added
  /// 2026-09-22). 2%, per explicit request — enough to absorb ordinary
  /// floating-point rounding across several sections, nowhere near enough
  /// to hide a real miscount.
  static const double kToleranceFraction = 0.02;

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
    // section sum, the paper wins — scale to it. (This preserves the
    // awarded/possible RATIO exactly, so it can never itself be the cause
    // of an out-of-range result — see the safeguard below, which is what
    // actually catches a bad input.)
    final paperTotal = rubric?.paperTotalMarks;
    if (paperTotal != null && paperTotal > 0 && totalPossible > 0 && (paperTotal - totalPossible).abs() > 0.01) {
      totalAwarded = (totalAwarded / totalPossible) * paperTotal;
      totalPossible = paperTotal;
    }

    // Stage 2 safeguard (added 2026-09-22, after a real incident: a single
    // miskeyed/misread mark on a History paper — one question's own
    // marksAwarded far exceeding its maxMarks — produced a "900 / 100"
    // result that was shown to a teacher as a real score). The AI/manual
    // entry is NOT trusted to have kept every mark within its own maximum;
    // this is the one place that independently checks the arithmetic
    // actually adds up, regardless of how the numbers got here.
    final reasons = <String>[];
    if (totalAwarded < -0.001) {
      reasons.add('the total came out negative (${ConciseScore.fmt(totalAwarded)})');
    } else if (totalPossible > 0 && totalAwarded > totalPossible * (1 + kToleranceFraction)) {
      reasons.add(
        'the total (${ConciseScore.fmt(totalAwarded)}) is more than the paper\'s own total '
        '(${ConciseScore.fmt(totalPossible)})',
      );
    } else if (totalPossible <= 0 && totalAwarded > 0.001) {
      reasons.add('marks were awarded (${ConciseScore.fmt(totalAwarded)}) but the paper\'s total came out as zero');
    }

    final structureError = reasons.isNotEmpty;
    if (structureError) {
      // Name the specific answer(s) that look impossible on their own, to
      // help a teacher find the actual miskeyed mark rather than just
      // knowing "something" is wrong.
      final culprits = [
        for (final a in answers)
          if (a.marksAwarded < -0.001 || (a.maxMarks > 0 && a.marksAwarded > a.maxMarks * (1 + kToleranceFraction)))
            '${a.questionLabel} (${ConciseScore.fmt(a.marksAwarded)} of ${ConciseScore.fmt(a.maxMarks)})',
      ];
      if (culprits.isNotEmpty) reasons.add('likely cause: ${culprits.join(', ')}');
    }

    // Halt automatic scaling for a flagged script: the section-by-section
    // breakdown above is still returned in full (a teacher needs it to see
    // where the miscount happened) but the headline awarded/possible/
    // percentage are never trusted downstream — see ConciseScore's own
    // outOf100Label/rawFractionLabel/roundedPercent, which refuse to show
    // them even if a caller forgets to check [structureError] itself.
    final percentage = totalPossible <= 0 ? 0.0 : (totalAwarded / totalPossible) * 100;

    return ConciseScore(
      sections: sectionScores,
      awardedMarks: totalAwarded,
      possibleMarks: totalPossible,
      percentage: percentage,
      rubricApplied: rubricApplied,
      structureError: structureError,
      structureErrorReason: structureError ? reasons.join('; ') : null,
    );
  }

  /// Marking Scheme Structure Stage 6 (2026-09-22) — the tree-aware
  /// counterpart to [compute], for the KEYED marking flow's real
  /// Section -> Question -> Part -> Sub-part scheme ([MarkingSchemeSection],
  /// see marking_scheme_node.dart) rather than the Concise flow's
  /// cover-page-derived [MarkingRubric]. The one rule this exists to
  /// enforce: a section's "answer any N" selection picks the candidate's
  /// best N TOP-LEVEL Questions — never a Part or Sub-part on its own, and
  /// never more marks than N whole questions' worth. Every one of a
  /// question's own Parts/Sub-parts is combined into ONE attempt first
  /// (summed, matching how [MarkingSchemeNode.totalMarks] is always
  /// computed, never stored), and only THAT combined attempt is ranked/
  /// selected — closing the exact bug class that made a question's own
  /// sub-parts look like independent siblings once flattened.
  ConciseScore computeForSections({
    required List<GradedAnswer> answers,
    required List<MarkingSchemeSection> sections,
  }) {
    final answerByLabel = {for (final a in answers) a.questionLabel: a};
    final sectionScores = <SectionScore>[];

    for (final section in sections) {
      final attempts = <_TopLevelAttempt>[];
      for (final q in section.questions) {
        var awarded = 0.0;
        var attempted = false;
        for (final (fullLabel, _) in q.leaves()) {
          final a = answerByLabel[fullLabel];
          if (a == null) continue;
          awarded += a.marksAwarded;
          attempted = true;
        }
        // A question with no graded answer for any of its own leaves at
        // all wasn't attempted — never counted, never "ignored" either
        // (there's nothing to ignore).
        if (!attempted) continue;
        attempts.add(_TopLevelAttempt(label: q.fullLabel(null), awarded: awarded, possible: q.totalMarks));
      }

      final required = section.requiredAnswerCount;
      List<_TopLevelAttempt> counted;
      List<_TopLevelAttempt> ignored;
      if (required != null && required > 0 && required < attempts.length) {
        final ranked = [...attempts]..sort(_bestFirstAttempt);
        counted = ranked.take(required).toList();
        ignored = ranked.skip(required).toList();
      } else {
        counted = attempts;
        ignored = const [];
      }

      final sectionAwarded = counted.fold<double>(0, (s, a) => s + a.awarded);
      // Uses the SCHEME's own defined totals for the counted questions —
      // never a candidate-dependent number — same reasoning as compute()'s
      // own `allocated` handling.
      final sectionPossible = counted.fold<double>(0, (s, a) => s + a.possible);

      sectionScores.add(SectionScore(
        name: section.name.trim().isEmpty ? 'All questions' : section.name,
        awarded: sectionAwarded,
        possible: sectionPossible,
        countedQuestions: counted.length,
        ignoredExcessQuestions: ignored.length,
        countedLabels: [for (final a in counted) a.label],
        ignoredLabels: [for (final a in ignored) a.label],
      ));
    }

    final totalAwarded = sectionScores.fold<double>(0, (s, sec) => s + sec.awarded);
    final totalPossible = sectionScores.fold<double>(0, (s, sec) => s + sec.possible);

    // Same Stage 2 safeguard as compute() — see that method's own comment
    // for the real incident this guards against.
    final reasons = <String>[];
    if (totalAwarded < -0.001) {
      reasons.add('the total came out negative (${ConciseScore.fmt(totalAwarded)})');
    } else if (totalPossible > 0 && totalAwarded > totalPossible * (1 + kToleranceFraction)) {
      reasons.add(
        'the total (${ConciseScore.fmt(totalAwarded)}) is more than the paper\'s own total '
        '(${ConciseScore.fmt(totalPossible)})',
      );
    } else if (totalPossible <= 0 && totalAwarded > 0.001) {
      reasons.add('marks were awarded (${ConciseScore.fmt(totalAwarded)}) but the paper\'s total came out as zero');
    }

    final structureError = reasons.isNotEmpty;
    if (structureError) {
      final culprits = [
        for (final a in answers)
          if (a.marksAwarded < -0.001 || (a.maxMarks > 0 && a.marksAwarded > a.maxMarks * (1 + kToleranceFraction)))
            '${a.questionLabel} (${ConciseScore.fmt(a.marksAwarded)} of ${ConciseScore.fmt(a.maxMarks)})',
      ];
      if (culprits.isNotEmpty) reasons.add('likely cause: ${culprits.join(', ')}');
    }

    final percentage = totalPossible <= 0 ? 0.0 : (totalAwarded / totalPossible) * 100;

    return ConciseScore(
      sections: sectionScores,
      awardedMarks: totalAwarded,
      possibleMarks: totalPossible,
      percentage: percentage,
      rubricApplied: sections.isNotEmpty,
      structureError: structureError,
      structureErrorReason: structureError ? reasons.join('; ') : null,
    );
  }

  /// Higher raw mark first; then higher proportion of the question's own
  /// maximum; then leave the original order alone.
  int _bestFirstAttempt(_TopLevelAttempt a, _TopLevelAttempt b) {
    final byMark = b.awarded.compareTo(a.awarded);
    if (byMark != 0) return byMark;
    final ra = a.possible <= 0 ? 0.0 : a.awarded / a.possible;
    final rb = b.possible <= 0 ? 0.0 : b.awarded / b.possible;
    return rb.compareTo(ra);
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

/// One top-level Question's combined result, for [ConciseScoreCalculator
/// .computeForSections] — every one of its own Parts/Sub-parts already
/// summed into a single [awarded]/[possible] pair, so "answer any N"
/// selection ranks/picks whole questions, never a fragment of one.
class _TopLevelAttempt {
  final String label;
  final double awarded;
  final double possible;
  const _TopLevelAttempt({required this.label, required this.awarded, required this.possible});
}
