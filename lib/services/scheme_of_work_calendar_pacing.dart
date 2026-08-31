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
///
/// Real bug fixed here (2026-08-31, second pass): several subjects rebuilt
/// this same day (Geography, Civic Education) genuinely have REAL week
/// data for MOST of their topics but not all — a handful of topics were
/// deliberately left without a real week because the second real source
/// simply didn't cover them (e.g. Geography Grade 12's Power/Energy
/// topics; Civic Education's cross-grade Human Rights topics). The
/// original all-or-nothing check below (`hasRealWeekData` → skip pacing
/// entirely) treated ANY real week data as "fully sourced," so those
/// leftover topics kept only [SchemeOfWorkEntry.weekNumber]'s raw
/// sequential fallback — a single counter incrementing across the WHOLE
/// syllabus (every term concatenated, see generateSchemeOfWork), not
/// reset per term. A Term 3 topic with no real week could easily end up
/// labelled "Week 47" — read by a teacher as the schedule being broken or
/// badly short, exactly the "shortened to 11 or 9 weeks" symptom
/// reported. Now: entries that DO have a real week are left completely
/// alone; entries that don't are paced into whichever of the term's real
/// 1-13 slots (minus week 7) aren't already claimed by a real-week entry,
/// using the same stretch/pack apportionment as the no-real-data case —
/// so a partially-sourced subject still fills out its real term instead
/// of falling back to a syllabus-wide counter that means nothing calendar-
/// wise.
List<SchemeOfWorkEntry> applyCalendarPacing(List<SchemeOfWorkEntry> entries) {
  if (entries.isEmpty) return entries;

  final realSlots = [for (var w = 1; w <= TermDates.totalWeeks; w++) if (w != TermDates.midtermBreakWeek) w];
  final withoutReal = entries.where((e) => e.realWeekNumber == null).toList();

  if (withoutReal.isEmpty) {
    // Every entry already has real week data — nothing to pace.
    return entries;
  }

  if (withoutReal.length < entries.length) {
    return _paceMixedRealAndMissing(entries, withoutReal, realSlots);
  }

  // No real week data at all — pure algorithmic pacing across the whole
  // term, exactly as before.
  const teachingWeeks = TermDates.teachingWeekCount; // 12

  // Real bug fixed here (2026-08-31): a subject can genuinely have MORE
  // topics/sub-topics than there are real teaching weeks (e.g. Geography
  // Grade 12: 25 entries against 12 real weeks) — the "stretch a few
  // entries across many weeks" logic below assumed the opposite direction
  // always held, and would try to hand out more weeks than physically
  // exist, throwing on the very next real device that hit it (confirmed:
  // `int.clamp` with a negative upper bound). When there's more content
  // than weeks, this now does the inverse — pack multiple entries into
  // the same real week — rather than assuming stretching is always the
  // right direction.
  if (entries.length > realSlots.length) {
    final entriesPerWeek = _allocateWeeks(List.filled(realSlots.length, 1), entries.length);
    final paced = <SchemeOfWorkEntry>[];
    var entryIndex = 0;
    for (var w = 0; w < realSlots.length; w++) {
      final count = entriesPerWeek[w].clamp(0, entries.length - entryIndex);
      for (var c = 0; c < count; c++) {
        paced.add(_withWeekNumber(entries[entryIndex], realSlots[w]));
        entryIndex++;
      }
    }
    // Apportionment always sums to entries.length when entries.length >=
    // realSlots.length (every week's floor is at least 1), so entryIndex
    // reaching the end here is guaranteed, not just hoped for — but if
    // that ever stops holding, the remainder still gets real week numbers
    // (piled onto the last week) rather than silently dropped.
    while (entryIndex < entries.length) {
      paced.add(_withWeekNumber(entries[entryIndex], realSlots.last));
      entryIndex++;
    }
    return paced;
  }

  final weeksPerEntry = _allocateWeeks(
    entries.map(_pacingWeight).toList(),
    teachingWeeks,
  );

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

/// Handles the case where some entries have real week data and some
/// don't — see this file's own doc comment for why this exists. Every
/// real-week entry is kept exactly as it was; every entry without one is
/// assigned a real week from whatever slots the real-week entries don't
/// already occupy, using the same largest-remainder apportionment as the
/// no-real-data path. The result is sorted by resolved real week —
/// downstream consumers (CBC's per-week "Lesson N" numbering, OBC's
/// group-by-week rows) both assume ascending week order.
List<SchemeOfWorkEntry> _paceMixedRealAndMissing(
  List<SchemeOfWorkEntry> entries,
  List<SchemeOfWorkEntry> withoutReal,
  List<int> realSlots,
) {
  final usedRealWeeks = entries.map((e) => e.realWeekNumber).whereType<int>().toSet();
  final openSlots = realSlots.where((w) => !usedRealWeeks.contains(w)).toList();

  final List<SchemeOfWorkEntry> pacedMissing;
  if (openSlots.isEmpty) {
    // Every real slot is already claimed by a real-week entry — pile the
    // rest onto the term's last real slot rather than leaving them on the
    // syllabus-wide sequential counter.
    pacedMissing = [for (final e in withoutReal) _withWeekNumber(e, realSlots.last)];
  } else if (withoutReal.length > openSlots.length) {
    final perSlot = _allocateWeeks(List.filled(openSlots.length, 1), withoutReal.length);
    final paced = <SchemeOfWorkEntry>[];
    var idx = 0;
    for (var w = 0; w < openSlots.length; w++) {
      final count = perSlot[w].clamp(0, withoutReal.length - idx);
      for (var c = 0; c < count; c++) {
        paced.add(_withWeekNumber(withoutReal[idx], openSlots[w]));
        idx++;
      }
    }
    while (idx < withoutReal.length) {
      paced.add(_withWeekNumber(withoutReal[idx], openSlots.last));
      idx++;
    }
    pacedMissing = paced;
  } else {
    final weeksPerEntry = _allocateWeeks(withoutReal.map(_pacingWeight).toList(), openSlots.length);
    final paced = <SchemeOfWorkEntry>[];
    var slotIndex = 0;
    for (var i = 0; i < withoutReal.length; i++) {
      final span = weeksPerEntry[i].clamp(1, openSlots.length - slotIndex);
      for (var s = 0; s < span; s++) {
        paced.add(_withWeekNumber(withoutReal[i], openSlots[slotIndex.clamp(0, openSlots.length - 1)]));
        slotIndex++;
      }
    }
    pacedMissing = paced;
  }

  final result = [
    for (final e in entries)
      if (e.realWeekNumber != null) e,
    ...pacedMissing,
  ];
  result.sort((a, b) => (a.realWeekNumber ?? a.weekNumber).compareTo(b.realWeekNumber ?? b.weekNumber));
  return result;
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
