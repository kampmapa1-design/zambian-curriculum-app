import 'syllabus_models.dart';
import 'zambian_term_calendar.dart';

/// One row of a generated scheme of work: either a whole topic (when it has
/// no sub-topics, or carries its own objectives/competencies directly) or
/// one of its sub-topics.
class SchemeOfWorkEntry {
  /// Sequential fallback numbering (1, 2, 3, ... in topic/sub-topic order) —
  /// always present, used when no sourced scheme of work gives a real week.
  final int weekNumber;
  final Topic topic;
  final SubTopic? subTopic;
  final List<LearningObjective> objectives;
  final List<Competency> competencies;

  /// False only when [applyCalendarPacing] has determined this entry's own
  /// sourced week number can't be trusted for THIS generation — see that
  /// function's own doc comment. [topic]/[subTopic] are immutable models
  /// shared with every other generation of the same syllabus, so their own
  /// `weekNumber` can't just be cleared there; this flag is what makes
  /// [realWeekNumber] correctly report "nothing real to go on" for this
  /// specific generation without touching the underlying syllabus data at
  /// all. True (trust it) for every entry until proven otherwise.
  final bool realWeekTrusted;

  const SchemeOfWorkEntry({
    required this.weekNumber,
    required this.topic,
    this.subTopic,
    required this.objectives,
    required this.competencies,
    this.realWeekTrusted = true,
  });

  String get title => subTopic == null ? topic.name : '${topic.name} — ${subTopic!.name}';

  /// The real teaching week from a sourced scheme of work, when known — see
  /// [SubTopic.weekNumber]. Null for content ingested before real week data
  /// was tracked, OR when [realWeekTrusted] is false; callers should fall
  /// back to [weekNumber] in either case.
  int? get realWeekNumber => realWeekTrusted ? (subTopic?.weekNumber ?? topic.weekNumber) : null;

  /// Real sourced reference material, when known — see
  /// [SubTopic.references]. Null for content with no sourced references
  /// yet; callers should fall back to a generic syllabus citation rather
  /// than leaving the References column blank.
  String? get references => subTopic?.references ?? topic.references;
}

/// Groups [entries] by [SchemeOfWorkEntry.realWeekNumber] for a week-picker
/// UI, sorted by week. Returns an empty map if none of the entries have real
/// week data — callers should fall back to a plain topic list in that case
/// rather than showing an empty "pick a week" dropdown.
Map<int, List<SchemeOfWorkEntry>> groupEntriesByRealWeek(List<SchemeOfWorkEntry> entries) {
  final byWeek = <int, List<SchemeOfWorkEntry>>{};
  for (final entry in entries) {
    final week = entry.realWeekNumber;
    if (week == null) continue;
    byWeek.putIfAbsent(week, () => []).add(entry);
  }
  return Map.fromEntries(byWeek.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}

/// Flattens a template's topics into one globally ordered list. Terms and
/// each term's topics are already sequence-sorted by local storage, so this
/// is just concatenation, not a fresh sort.
List<Topic> flattenTopics(SyllabusTemplate template) => [
      for (final term in template.terms) ...term.topics,
    ];

/// Every topic/sub-topic entry for [template], from the very first topic,
/// numbered as consecutive weeks starting at 1 — the full, unbounded
/// sequence [generateSchemeOfWork] slices into. Not `flattenTopics` (which
/// stops at [Topic] granularity): this descends into sub-topics too, in the
/// exact order a generated scheme presents them. Public (2026-09-04, was
/// `_allEntries`) — "Topics in the Scheme" lists directly from this same
/// authoritative source, so its list can never drift out of sync with what
/// a generated scheme actually contains.
List<SchemeOfWorkEntry> allSchemeOfWorkEntries(SyllabusTemplate template) {
  final entries = <SchemeOfWorkEntry>[];
  var week = 1;
  for (final topic in flattenTopics(template)) {
    final hasOwnContent = topic.objectives.isNotEmpty || topic.competencies.isNotEmpty;
    if (hasOwnContent || topic.subTopics.isEmpty) {
      entries.add(SchemeOfWorkEntry(
        weekNumber: week++,
        topic: topic,
        objectives: topic.objectives,
        competencies: topic.competencies,
      ));
    }
    for (final subTopic in topic.subTopics) {
      entries.add(SchemeOfWorkEntry(
        weekNumber: week++,
        topic: topic,
        subTopic: subTopic,
        objectives: subTopic.objectives,
        competencies: subTopic.competencies,
      ));
    }
  }
  return entries;
}

/// Builds the next stretch of a scheme of work: every topic/sub-topic that
/// comes strictly after the given resume point, in sequence, renumbered as
/// consecutive weeks starting at 1 — spilling across term boundaries freely,
/// since the guiding principle is real coverage (nothing taught twice,
/// nothing skipped), not which term a topic happened to be filed under. See
/// ClassResumePickerScreen for where the resume point comes from.
///
/// Pass `null` for [lastConcludedTopicId] to generate a scheme from the very
/// first topic (e.g. a subject the teacher hasn't started yet). If the given
/// topic id isn't found in this template (stale progress from a template
/// that changed), the scheme also starts from the beginning rather than
/// silently omitting it.
///
/// [lastConcludedSubTopicId], when given alongside [lastConcludedTopicId],
/// resumes right after that SPECIFIC sub-topic — for a class that stopped
/// partway through a topic with several sub-topics, so the remaining
/// sub-topics of that same topic are correctly picked up rather than either
/// re-taught or skipped. Left null, [lastConcludedTopicId] alone means the
/// whole topic (every one of its sub-topics) was concluded, and the scheme
/// resumes at the following topic.
List<SchemeOfWorkEntry> generateSchemeOfWork(
  SyllabusTemplate template,
  int? lastConcludedTopicId, {
  int? lastConcludedSubTopicId,
}) {
  final allEntries = allSchemeOfWorkEntries(template);
  if (allEntries.isEmpty) return const [];

  int startIndex;
  if (lastConcludedTopicId == null) {
    startIndex = 0;
  } else if (lastConcludedSubTopicId != null) {
    final entryIndex = allEntries.indexWhere(
      (e) => e.topic.id == lastConcludedTopicId && e.subTopic?.id == lastConcludedSubTopicId,
    );
    startIndex = entryIndex == -1 ? 0 : entryIndex + 1;
  } else {
    final topics = flattenTopics(template);
    final topicIndex = topics.indexWhere((t) => t.id == lastConcludedTopicId);
    if (topicIndex == -1) {
      startIndex = 0;
    } else if (topicIndex + 1 >= topics.length) {
      return const [];
    } else {
      final nextTopicId = topics[topicIndex + 1].id;
      startIndex = allEntries.indexWhere((e) => e.topic.id == nextTopicId);
      if (startIndex == -1) return const [];
    }
  }
  if (startIndex >= allEntries.length) return const [];

  final sliced = allEntries.sublist(startIndex);
  return [
    for (var i = 0; i < sliced.length; i++)
      SchemeOfWorkEntry(
        weekNumber: i + 1,
        topic: sliced[i].topic,
        subTopic: sliced[i].subTopic,
        objectives: sliced[i].objectives,
        competencies: sliced[i].competencies,
      ),
  ];
}

/// [generateSchemeOfWork], capped to how many entries actually fit in one
/// real term's teaching time ([TermDates.teachingWeekCount] — the same
/// fixed real-calendar figure every term uses, midterm break and
/// end-of-term week already excluded). This is what lets one term's
/// generated scheme legitimately spill into a later term's own original
/// topics (or fall short of reaching them, if a class is behind) — the cap
/// is real available teaching time, not "does this topic belong to the
/// term I picked."
List<SchemeOfWorkEntry> generateSchemeOfWorkForTerm(
  SyllabusTemplate template,
  int? lastConcludedTopicId, {
  int? lastConcludedSubTopicId,
}) {
  final entries = generateSchemeOfWork(template, lastConcludedTopicId, lastConcludedSubTopicId: lastConcludedSubTopicId);
  return entries.length <= TermDates.teachingWeekCount ? entries : entries.sublist(0, TermDates.teachingWeekCount);
}

/// The exact per-term topic/week windows a brand-new class's Scheme of
/// Work would show — [generateSchemeOfWorkForTerm] applied term by term,
/// each term picking up exactly where the previous term's own window left
/// off (chained the same way a real continuing class's resume point
/// chains), starting from the very first topic. `windows[i]` is
/// `template.terms[i]`'s window.
///
/// Real, reported bug this fixes (2026-09-06): a subject whose real
/// per-term topic count doesn't match Zambia's real per-term teaching-week
/// count spills content across term boundaries by design (see
/// [generateSchemeOfWorkForTerm]'s own doc comment — e.g. Physical
/// Education Grade 10's Term 1 has only 10 real sub-topic entries against
/// 11 real teaching weeks, so a fresh Term 1 Scheme of Work already pulls
/// its 11th week from Term 2's own first topic). [TermTopicPickerScreen]
/// used to group topics by each topic's own AUTHORED JSON term instead of
/// by this real generated placement, so a topic a generated Scheme of Work
/// placed in "Term 1, Week 11" (or later, for a subject that spills
/// further) could only ever be found under a DIFFERENT term's tile when
/// picking a topic to generate a lesson plan for — exactly the mismatch
/// reported (PE10.9.2, Term 3 in the syllabus JSON, showing up in a Term 1
/// Scheme of Work). This function is the one place both screens now read
/// term/week placement from, so the two can never drift apart again for
/// the case this fixes.
///
/// This guarantees parity only for a class starting fresh (no resume
/// progress recorded yet) — also exactly the state a teacher is in the
/// first time they generate a term's Scheme of Work for a subject. A real
/// class whose OWN tracked progress has since fallen behind or run ahead
/// of this fresh baseline will see its own Scheme of Work legitimately
/// differ from these windows from then on; there is no way to predict that
/// from the template alone, since it depends on that specific class's own
/// recorded history, not on the syllabus content.
///
/// Slices [allSchemeOfWorkEntries] directly by INDEX rather than chaining
/// through [generateSchemeOfWorkForTerm]'s own topic/sub-topic-id "resume"
/// parameters — a real edge case surfaced while testing this against every
/// bundled subject (2026-09-06): `design_and_technology_form1`'s "GRAPHICS"
/// topic carries its own content directly AND has further sub-topics of
/// its own after it. When a term's window happened to end exactly on that
/// topic's own top-level entry, resuming via `lastConcludedTopicId` alone
/// (no sub-topic id, since a topic-level entry has none) is genuinely
/// ambiguous with [generateSchemeOfWork]'s OTHER real meaning for that same
/// input — "the whole topic, every one of its sub-topics included, was
/// concluded" (the real semantic a class's own tracked resume progress
/// needs) — so it skipped straight to the NEXT topic, silently dropping
/// "GRAPHICS — SYMBOLS" and "GRAPHICS — INTRODUCTION TO COMPUTER AIDED
/// DESIGN (CAD)" from every later window. Slicing by index instead has no
/// such ambiguity: "the next window starts at the entry right after the
/// last one" is exactly what it says, always.
List<List<SchemeOfWorkEntry>> schemeOfWorkTermWindows(SyllabusTemplate template) {
  final all = allSchemeOfWorkEntries(template);
  final windows = <List<SchemeOfWorkEntry>>[];
  var cursor = 0;
  for (var i = 0; i < template.terms.length; i++) {
    if (cursor >= all.length) {
      windows.add(const []);
      continue;
    }
    final end = (cursor + TermDates.teachingWeekCount).clamp(cursor, all.length);
    final slice = all.sublist(cursor, end);
    windows.add([
      for (var j = 0; j < slice.length; j++)
        SchemeOfWorkEntry(
          weekNumber: j + 1,
          topic: slice[j].topic,
          subTopic: slice[j].subTopic,
          objectives: slice[j].objectives,
          competencies: slice[j].competencies,
        ),
    ]);
    cursor = end;
  }
  return windows;
}

/// Groups [entries] by each entry's EFFECTIVE week — its real sourced week
/// when known, else its own [SchemeOfWorkEntry.weekNumber] (which, for
/// entries already run through [applyCalendarPacing], IS the same
/// calendar-paced/stretched week a generated Scheme of Work document
/// actually presents — see that function's own doc comment). Unlike
/// [groupEntriesByRealWeek], this never comes back empty just because a
/// subject has no real sourced week data of its own — the common case (see
/// [schemeOfWorkTermWindows]'s own doc comment), and exactly the case the
/// reported topic/lesson-plan mismatch happened in.
Map<int, List<SchemeOfWorkEntry>> groupEntriesByEffectiveWeek(List<SchemeOfWorkEntry> entries) {
  final byWeek = <int, List<SchemeOfWorkEntry>>{};
  for (final entry in entries) {
    final week = entry.realWeekNumber ?? entry.weekNumber;
    byWeek.putIfAbsent(week, () => []).add(entry);
  }
  return Map.fromEntries(byWeek.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}

/// "Topics in the Scheme" (2026-09-04, per explicit request): builds a
/// full term's scheme of work with [start] as its very FIRST entry,
/// regardless of any class's real tracked progress — a teacher picking a
/// specific topic directly rather than resuming from where a real class
/// left off. Slices [allSchemeOfWorkEntries] from [start]'s own position
/// onward and caps it the same way [generateSchemeOfWorkForTerm] does,
/// rather than going through [generateSchemeOfWork]'s "resume after X"
/// indirection — that machinery means something different (a topic with
/// its own content AND sub-topics is treated as fully concluded, skipping
/// straight to the next topic, once its sub-topics are done) that would
/// silently skip content here if [start] happened to land right after
/// such a topic. Falls back to generating from the very beginning if
/// [start] can't be found in [template] (e.g. stale content).
List<SchemeOfWorkEntry> generateSchemeOfWorkStartingAt(SyllabusTemplate template, SchemeOfWorkEntry start) {
  final all = allSchemeOfWorkEntries(template);
  final index = all.indexWhere((e) => e.topic.id == start.topic.id && e.subTopic?.id == start.subTopic?.id);
  final sliced = index == -1 ? all : all.sublist(index);
  final capped = sliced.length <= TermDates.teachingWeekCount ? sliced : sliced.sublist(0, TermDates.teachingWeekCount);
  return [
    for (var i = 0; i < capped.length; i++)
      SchemeOfWorkEntry(
        weekNumber: i + 1,
        topic: capped[i].topic,
        subTopic: capped[i].subTopic,
        objectives: capped[i].objectives,
        competencies: capped[i].competencies,
      ),
  ];
}
