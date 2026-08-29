import '../models/scheme_of_work.dart';
import '../models/zambian_term_calendar.dart';

/// The real bug this fixes: most bundled CBC subjects have far fewer
/// authored topics/sub-topics than a real 13-week Zambian school term has
/// teaching weeks (verified 2026-08-29 — e.g. Chemistry Form 1 Term 2 has
/// exactly 6 topic units, no real week data), so the old generator (1
/// topic = 1 sequential week) produced schemes covering only 6 of 13
/// weeks, silently, with nothing indicating the other 7 weeks were simply
/// missing.
///
/// This spreads the SAME real topics across the term's real 12 teaching
/// weeks (13 weeks minus the mid-term break — see zambian_term_calendar.dart)
/// when there aren't enough distinct topics to fill every week 1:1 —
/// pacing stretched, never inventing new content. Where a subject's
/// syllabus data DOES carry real per-topic week numbers already (a
/// minority of subjects, e.g. civic_education_form2), that real data is
/// left completely alone; this is a fallback for the common case of no
/// real week data at all, not an override of real sourced data.
List<SchemeOfWorkEntry> applyCalendarPacing(List<SchemeOfWorkEntry> entries) {
  if (entries.isEmpty) return entries;
  final hasRealWeekData = entries.any((e) => e.realWeekNumber != null);
  if (hasRealWeekData) return entries;

  const teachingWeeks = TermDates.teachingWeekCount; // 12
  final weeksPerEntry = _allocateWeeks(
    entries.map(_pacingWeight).toList(),
    teachingWeeks,
  );

  // Real week slots a teaching week can land on: 1-6, then 8-13 — week 7
  // is reserved for the mid-term break and is never assigned a topic here
  // (see applyCalendarPacingWithMidtermRow, which inserts that row
  // explicitly at the document-building layer).
  final realSlots = [for (var w = 1; w <= TermDates.totalWeeks; w++) if (w != TermDates.midtermBreakWeek) w];

  final paced = <SchemeOfWorkEntry>[];
  var slotIndex = 0;
  for (var i = 0; i < entries.length; i++) {
    final span = weeksPerEntry[i].clamp(1, realSlots.length - slotIndex);
    for (var s = 0; s < span; s++) {
      final realWeek = realSlots[(slotIndex).clamp(0, realSlots.length - 1)];
      paced.add(_withWeekNumber(entries[i], realWeek));
      slotIndex++;
    }
  }
  return paced;
}

/// A topic's "how much time does this deserve" proxy — more competencies/
/// objectives suggests more content to cover. Always at least 1, so every
/// real topic gets at least one real week, never silently dropped.
int _pacingWeight(SchemeOfWorkEntry e) => 1 + e.competencies.length + e.objectives.length;

/// Largest-remainder apportionment: allocates [totalWeeks] whole weeks
/// across entries proportional to [weights], every entry getting at least
/// one week, summing to exactly [totalWeeks].
List<int> _allocateWeeks(List<int> weights, int totalWeeks) {
  final n = weights.length;
  final totalWeight = weights.fold<int>(0, (a, b) => a + b);
  final raw = [for (final w in weights) w * totalWeeks / totalWeight];
  final base = [for (final r in raw) r.floor()];

  for (var i = 0; i < n; i++) {
    if (base[i] < 1) base[i] = 1;
  }
  var remaining = totalWeeks - base.fold<int>(0, (a, b) => a + b);

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

SchemeOfWorkEntry _withWeekNumber(SchemeOfWorkEntry e, int weekNumber) => SchemeOfWorkEntry(
      weekNumber: weekNumber,
      topic: e.topic,
      subTopic: e.subTopic,
      objectives: e.objectives,
      competencies: e.competencies,
    );
