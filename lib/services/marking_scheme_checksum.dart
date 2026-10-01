import '../models/marking_scheme_node.dart';

/// Marking Scheme Structure Stage 5 (2026-09-22) — after all sections are
/// confirmed/edited on the structure-confirmation screen, does the tree's
/// own real total (every section's own [MarkingSchemeSection
/// .totalMarksIfAllAnswered], summed) actually match what the paper itself
/// states? A real, deliberately-broken leaf (a mark far exceeding what a
/// section/question could plausibly hold — the exact bug pattern behind
/// the History "900/100" incident, see ConciseScoreCalculator's own Stage
/// 2 safeguard) throws this off by far more than ordinary rounding could,
/// which is exactly what this exists to catch BEFORE the scheme is ever
/// used to grade a real script.
class MarkingSchemeChecksumResult {
  final bool matches;
  final double sumOfSections;
  final double? statedTotal;

  /// [sumOfSections] - [statedTotal] — 0 when there's no stated total to
  /// compare against (nothing to check, so [matches] is always true then).
  final double difference;

  const MarkingSchemeChecksumResult({
    required this.matches,
    required this.sumOfSections,
    this.statedTotal,
    required this.difference,
  });
}

/// 2%, same tolerance as ConciseScoreCalculator.kToleranceFraction — enough
/// to absorb an assumed/estimated mark on a question the paper itself
/// didn't explicitly allocate (see the extraction prompt's own "make a
/// reasonable estimate" instruction), nowhere near enough to hide a real
/// miscount.
const double kMarkingSchemeChecksumTolerance = 0.02;

MarkingSchemeChecksumResult checkMarkingSchemeChecksum({
  required List<MarkingSchemeSection> sections,
  double? statedGrandTotal,
  double toleranceFraction = kMarkingSchemeChecksumTolerance,
}) {
  final sum = sections.fold(0.0, (s, sec) => s + sec.totalMarksIfAllAnswered);
  if (statedGrandTotal == null || statedGrandTotal <= 0) {
    return MarkingSchemeChecksumResult(matches: true, sumOfSections: sum, statedTotal: statedGrandTotal, difference: 0);
  }
  final diff = sum - statedGrandTotal;
  final matches = diff.abs() <= statedGrandTotal * toleranceFraction;
  return MarkingSchemeChecksumResult(matches: matches, sumOfSections: sum, statedTotal: statedGrandTotal, difference: diff);
}
