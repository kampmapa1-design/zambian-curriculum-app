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

/// One named grade band under a [GradingSystem] — e.g. "Distinction" for
/// British, "A" for American — with the percentage range that earns it.
class GradeBand {
  final String label;
  final double minPercentInclusive;

  const GradeBand({required this.label, required this.minPercentInclusive});
}

/// British-style bands, highest first. These percentage boundaries come
/// from a directly-quoted ECZ circular found during research (2026-08-28)
/// — Distinction 75-100, Merit 60-74, Credit 50-59, Satisfactory 40-49,
/// Fail 0-39 — but a second source gave a different Distinction/Merit
/// split (70 instead of 75). Flagged to the user rather than silently
/// resolved; change this one list if the correct figure turns out to be
/// different — nothing else in this feature needs to change.
const List<GradeBand> britishGradeBands = [
  GradeBand(label: 'Distinction', minPercentInclusive: 75),
  GradeBand(label: 'Merit', minPercentInclusive: 60),
  GradeBand(label: 'Credit', minPercentInclusive: 50),
  GradeBand(label: 'Satisfactory', minPercentInclusive: 40),
  GradeBand(label: 'Fail', minPercentInclusive: 0),
];

/// Standard American letter-grade convention. Unlike the British bands,
/// this one isn't contested in what was found - A/B/C/D/F on a 90/80/70/
/// 60 split is the near-universal convention.
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
