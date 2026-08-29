/// Which grading system the Analysis screen (AI-Assisted Marking) should
/// classify results under — asked via a timed pop-up each time Analysis
/// is opened (see MarkingAnalysisScreen), never assumed silently.
enum GradingSystem {
  british,
  american;

  String get label => switch (this) {
        GradingSystem.british => 'British',
        GradingSystem.american => 'American',
      };
}

/// One named grade band under a [GradingSystem] — the numbered ECZ-style
/// 1-9 scale for British, a plain letter for American — with the
/// percentage range that earns it. [numericGrade] is null for American,
/// since that system doesn't use one.
class GradeBand {
  final String label;
  final int? numericGrade;
  final double minPercentInclusive;

  const GradeBand({required this.label, this.numericGrade, required this.minPercentInclusive});

  /// "1st Class Distinction (1)" for British, "A" for American (no
  /// numeric grade to append).
  String get fullLabel => numericGrade == null ? label : '$label ($numericGrade)';
}

/// The full numbered 1-9 ECZ-style scale, highest first — not the
/// collapsed 5-band version (Distinction/Merit/Credit/Satisfactory/Fail)
/// used before this was refined: each of the 9 individual grades gets
/// its own named band, per the explicit spec (1st/2nd Class Distinction,
/// Merit 3/4, Credit 5/6, Pass 7/8, Fail 9).
///
/// Percentage boundaries come from a finer 9-point breakdown found during
/// research (2026-08-28) of ECZ's published grading circulars — the same
/// source whose collapsed 5-band totals (Distinction 75-100, Merit
/// 60-74, Credit 50-59, Satisfactory 40-49, Fail 0-39) a second source
/// broadly agreed with, disagreeing only on exactly where Distinction
/// ends and Merit begins (70 vs 75). This 9-point table resolves that by
/// construction (grade 1 starts at 75, grade 2 covers 70-74), but if ECZ's
/// exact current figures turn out to differ, this is the one list to
/// change — nothing else in this feature depends on the specific numbers.
///
/// **Re-checked 2026-08-29, deliberately NOT changed**: a follow-up search
/// surfaced intracolleges.com claiming the opposite direction entirely —
/// grade 9 = best/Distinction, grade 1 = worst/fail. That contradicts both
/// this table AND a separate ECZ Grade 9 source found in the same search
/// pass ("75-100: ONE DISTINCTION... 40-49: FOUR PASS" — grade 1 = best,
/// same direction as here). intracolleges.com is a low-authority SEO
/// aggregator, not ECZ itself, and disagrees with a more internally-
/// consistent source, so it was NOT used to change anything — flagging
/// this here rather than silently dropping the finding. Still genuinely
/// unverified against ECZ's own site directly; the "1 = best" direction
/// has two independent-ish sources now, the exact percentage cutoffs
/// still only one.
const List<GradeBand> britishGradeBands = [
  GradeBand(label: '1st Class Distinction', numericGrade: 1, minPercentInclusive: 75),
  GradeBand(label: '2nd Class Distinction', numericGrade: 2, minPercentInclusive: 70),
  GradeBand(label: 'Merit', numericGrade: 3, minPercentInclusive: 65),
  GradeBand(label: 'Merit', numericGrade: 4, minPercentInclusive: 60),
  GradeBand(label: 'Credit', numericGrade: 5, minPercentInclusive: 55),
  GradeBand(label: 'Credit', numericGrade: 6, minPercentInclusive: 50),
  GradeBand(label: 'Pass', numericGrade: 7, minPercentInclusive: 45),
  GradeBand(label: 'Pass', numericGrade: 8, minPercentInclusive: 40),
  GradeBand(label: 'Fail', numericGrade: 9, minPercentInclusive: 0),
];

/// Standard American letter-grade convention. Unlike the British bands,
/// this one isn't contested in what was found - A/B/C/D/F on a 90/80/70/
/// 60 split is the near-universal convention. No numeric grade — the
/// American system doesn't use one.
const List<GradeBand> americanGradeBands = [
  GradeBand(label: 'A', minPercentInclusive: 90),
  GradeBand(label: 'B', minPercentInclusive: 80),
  GradeBand(label: 'C', minPercentInclusive: 70),
  GradeBand(label: 'D', minPercentInclusive: 60),
  GradeBand(label: 'F', minPercentInclusive: 0),
];

List<GradeBand> gradeBandsFor(GradingSystem system) => switch (system) {
      GradingSystem.british => britishGradeBands,
      GradingSystem.american => americanGradeBands,
    };

/// Classifies a percentage score into its band under [system]. Bands are
/// checked highest-first so a boundary score (e.g. exactly 75%) lands in
/// the higher band, matching "X% and above" as these scales are
/// conventionally read.
GradeBand classify(double percent, GradingSystem system) {
  final bands = gradeBandsFor(system);
  for (final band in bands) {
    if (percent >= band.minPercentInclusive) return band;
  }
  return bands.last;
}
