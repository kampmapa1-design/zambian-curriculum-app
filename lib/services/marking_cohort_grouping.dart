import '../models/marking_scheme.dart';
import '../models/marking_script.dart';

/// Every distinct (scheme, cohort) pairing across [scripts] that has
/// actually entered the marking pipeline (queued or later — a script
/// still sitting at [MarkingScriptStatus.captured], not yet linked to
/// any scheme, isn't part of any cohort yet).
///
/// Real, reported gap this fixes (2026-09-05): the same marking key is
/// routinely reused across different classes/sittings (e.g. "History
/// Paper 1" marked for both 12A and 12B) — grouping by schemeId alone
/// would silently merge two genuinely different classes' scripts into
/// one cohort just because they share a marking key. This groups by
/// (schemeId, cohortName) instead — see [MarkingScript.cohortName]'s own
/// doc comment — so each named class stays its own cohort even when
/// several share one key. A script with no cohort name at all (saved
/// before the field existed) groups under '' same as always, scoped by
/// scheme alone — unchanged behavior for old data.
List<({MarkingScheme scheme, String cohortName})> activeMarkingCohorts(
  List<MarkingScript> scripts,
  List<MarkingScheme> schemes,
) {
  final pairs = <({String schemeId, String cohortName})>{};
  for (final s in scripts) {
    if (s.schemeId == null || s.status == MarkingScriptStatus.captured) continue;
    pairs.add((schemeId: s.schemeId!, cohortName: s.cohortName));
  }
  return [
    for (final pair in pairs)
      if (schemes.where((sc) => sc.id == pair.schemeId).firstOrNull case final scheme?)
        (scheme: scheme, cohortName: pair.cohortName),
  ];
}

/// The label a teacher sees for one [activeMarkingCohorts] entry — the
/// cohort's own name first (when it has one) so two classes sharing a
/// scheme are never confused for each other, falling back to just the
/// scheme's title for a script saved before cohort names existed.
String markingCohortLabel(({MarkingScheme scheme, String cohortName}) cohort) =>
    cohort.cohortName.trim().isEmpty ? cohort.scheme.title : '${cohort.cohortName} — ${cohort.scheme.title}';
