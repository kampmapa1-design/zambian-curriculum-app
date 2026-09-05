/// Largest-remainder apportionment: splits [total] whole units across
/// entries proportional to [weights], every entry with a positive weight
/// getting at least 1 unit (never silently zeroed out), summing to
/// EXACTLY [total] rather than drifting from independent rounding.
///
/// Shared by two real, otherwise-unrelated features that turned out to be
/// the same underlying problem — a fixed whole total that must be spread
/// proportionally across several things without the split's rounding
/// silently drifting from the real total:
///  - scheme_of_work_calendar_pacing.dart: how many real teaching weeks
///    each topic/sub-topic gets when there are fewer of them than weeks
///    in a term.
///  - marking_scheme_section_marks.dart: how many marks each question/
///    sub-part in an exam section gets once a teacher confirms that
///    section's own real total (e.g. "Section A = 30 marks").
List<int> allocateProportionally(List<num> weights, int total) {
  final n = weights.length;
  if (n == 0) return const [];
  final totalWeight = weights.fold<num>(0, (a, b) => a + b);
  final raw = totalWeight == 0
      ? [for (var i = 0; i < n; i++) total / n]
      : [for (final w in weights) w * total / totalWeight];
  final base = [for (final r in raw) r.floor()];

  for (var i = 0; i < n; i++) {
    if (base[i] < 1) base[i] = 1;
  }
  var remaining = total - base.fold<int>(0, (a, b) => a + b);

  if (remaining > 0) {
    final byFraction = List.generate(n, (i) => i)
      ..sort((a, b) => (raw[b] - raw[b].floor()).compareTo(raw[a] - raw[a].floor()));
    for (var k = 0; k < remaining; k++) {
      base[byFraction[k % n]] += 1;
    }
  } else if (remaining < 0) {
    final byWeeksDesc = List.generate(n, (i) => i)..sort((a, b) => base[b].compareTo(base[a]));
    var i = 0;
    while (remaining < 0 && i < n * 4) {
      final j = byWeeksDesc[i % n];
      if (base[j] > 1) {
        base[j] -= 1;
        remaining += 1;
      }
      i++;
    }
  }
  return base;
}
