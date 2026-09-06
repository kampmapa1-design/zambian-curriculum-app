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

/// Every real, authored topic/sub-topic entry for [term] ALONE (not the
/// whole syllabus) — see [allSchemeOfWorkEntries], scoped to just this
/// term's own topics and renumbered as consecutive weeks starting at 1
/// within it. This is "genuinely supported by the syllabus" for [term]
/// specifically, with no cross-term borrowing at all — [applyCalendarPacing]
/// is what stretches or packs this list to fill (or fit) the term's real
/// teaching weeks, whether it has too few or too many entries of its own.
List<SchemeOfWorkEntry> entriesForOwnTerm(SyllabusTemplate template, Term term) {
  final topicIds = term.topics.map((t) => t.id).toSet();
  final filtered = allSchemeOfWorkEntries(template).where((e) => topicIds.contains(e.topic.id)).toList();
  return [
    for (var i = 0; i < filtered.length; i++)
      SchemeOfWorkEntry(
        weekNumber: i + 1,
        topic: filtered[i].topic,
        subTopic: filtered[i].subTopic,
        objectives: filtered[i].objectives,
        competencies: filtered[i].competencies,
      ),
  ];
}

/// [generateSchemeOfWork], capped to how many entries actually fit in one
/// real term's teaching time ([TermDates.teachingWeekCount] — the same
/// fixed real-calendar figure every term uses, midterm break and
/// end-of-term week already excluded) — but ONLY when [lastConcludedTopicId]
/// is non-null, i.e. there is a REAL class resume point to honour. In that
/// case this is what lets one term's generated scheme legitimately spill
/// into a later term's own original topics (or fall short of reaching
/// them, if a class is behind) — the cap is real available teaching time,
/// not "does this topic belong to the term I picked," and that spillover
/// reflects that SPECIFIC class's own real, lived pace.
///
/// Real, reported bug fixed (2026-09-07): when [lastConcludedTopicId] is
/// null (a FRESH generation, no real class history yet — the common case
/// for "Generate Scheme of Work" the very first time, or any one-off) AND
/// [term] is given, this used to flatten the WHOLE syllabus and cap at one
/// term's real teaching weeks regardless — for a subject with few total
/// topics across the whole year (e.g. Physics Grade 11: 14 real entries
/// total; Principles of Accounts Form 2: 6), that front-loaded almost — or
/// literally all — of the subject's content into Term 1's own window,
/// leaving Term 2 and/or Term 3 completely empty ("No topics left to place
/// in this term") even though the syllabus genuinely DOES have real,
/// authored content for those terms (Physics 11.7 Magnetism in Term 3;
/// POA 2.3–2.5 in Terms 2–3). A fresh start has no real teaching history to
/// justify assuming a class is already "ahead of schedule" enough to need
/// content borrowed from a later term, so it now always uses exactly that
/// term's own authored topics via [entriesForOwnTerm] — [applyCalendarPacing]
/// alone already solves "not enough distinct topics for a whole term" by
/// stretching them across more weeks, with no cross-term borrowing needed
/// for that. [term] omitted (or a non-null [lastConcludedTopicId]) keeps
/// the original whole-syllabus-coverage behaviour, e.g. for a caller with
/// no term context, or for a real class's own resume point.
List<SchemeOfWorkEntry> generateSchemeOfWorkForTerm(
  SyllabusTemplate template,
  int? lastConcludedTopicId, {
  int? lastConcludedSubTopicId,
  Term? term,
}) {
  if (lastConcludedTopicId == null && term != null) {
    return entriesForOwnTerm(template, term);
  }
  final entries = generateSchemeOfWork(template, lastConcludedTopicId, lastConcludedSubTopicId: lastConcludedSubTopicId);
  return entries.length <= TermDates.teachingWeekCount ? entries : entries.sublist(0, TermDates.teachingWeekCount);
}

/// The exact per-term topic/week windows a brand-new class's Scheme of
/// Work would show — `windows[i]` is exactly `template.terms[i]`'s OWN
/// authored topics (see [entriesForOwnTerm]), independent of every other
/// term. A thin convenience over [schemeOfWorkTermWindowsFrom] with no
/// resume point — see that function's own doc comment for why a fresh
/// window is deliberately per-term rather than chained.
List<List<SchemeOfWorkEntry>> schemeOfWorkTermWindows(SyllabusTemplate template) =>
    schemeOfWorkTermWindowsFrom(template, null);

/// The exact per-term topic/week windows a SPECIFIC class's Scheme of Work
/// would show. `windows[i]` is `template.terms[i]`'s window.
///
/// **`lastConcludedTopicId` null (no real class history yet — a fresh
/// start, or a one-off):** each `windows[i]` is exactly
/// `template.terms[i]`'s OWN authored topics ([entriesForOwnTerm]), with NO
/// cross-term borrowing — matching [generateSchemeOfWorkForTerm]'s own
/// fresh-start behaviour (see that function's own doc comment for the real
/// reported bug this fixes: a subject with few total topics across the
/// whole year — e.g. Physics Grade 11, Principles of Accounts Form 2 —
/// used to have almost all of its content front-loaded into Term 1's
/// window by chained whole-syllabus coverage, leaving Term 2 and/or Term 3
/// completely empty even though the syllabus genuinely has real content
/// for them). This also keeps [TermTopicPickerScreen] naturally consistent
/// with a fresh Scheme of Work: a topic authored under Term 3 is found
/// under Term 3 in both, with no spillover to reconcile at all.
///
/// **`lastConcludedTopicId` non-null (a REAL class's own tracked resume
/// point):** [generateSchemeOfWork] is used from that point, and every
/// window is a consecutive [TermDates.teachingWeekCount]-sized slice of
/// what follows, spilling across term boundaries freely — this reflects
/// that SPECIFIC class's own real, lived pace (ahead of or behind the
/// calendar), which a fresh start has no basis to assume. The very first
/// window comes from [generateSchemeOfWork] itself — same starting point,
/// same quirks, as [generateSchemeOfWorkForTerm] for the same resume point
/// (what makes this genuinely match that function's own output for a real
/// class, rather than an independent reinterpretation of the same resume
/// point). Every LATER window, though, continues by INDEX from the
/// previous window's own last entry, never by re-encoding that entry back
/// into a topic/sub-topic-id pair and re-resolving it — a real edge case
/// surfaced while testing this against every bundled subject (2026-09-06):
/// `design_and_technology_form1`'s "GRAPHICS" topic carries its own
/// content directly AND has further sub-topics of its own after it, and a
/// null sub-topic id for such a topic collides with [generateSchemeOfWork]'s
/// OTHER real meaning for that same input, "the whole topic, every
/// sub-topic included, was concluded" — silently dropping "GRAPHICS —
/// SYMBOLS" and "GRAPHICS — INTRODUCTION TO COMPUTER AIDED DESIGN (CAD)"
/// from every later window when chained the naive way. Continuing by index
/// has no such ambiguity.
///
/// This function is the one place both the Scheme of Work generator and
/// every topic-first Lesson Plan flow now read term/week placement from,
/// so the two can never drift apart for either case above — a fresh class
/// (2026-09-06) or a specific class's own real resume point
/// (startGenerateLessonPlanFlow's "which class, where did it reach?" step).
/// Full parity for the resume-point case holds only for exactly the class
/// whose real resume point this was called with, and only as of when it
/// was called — that class's own record can always move again afterwards.
List<List<SchemeOfWorkEntry>> schemeOfWorkTermWindowsFrom(
  SyllabusTemplate template,
  int? lastConcludedTopicId, {
  int? lastConcludedSubTopicId,
}) {
  if (lastConcludedTopicId == null) {
    return [for (final term in template.terms) entriesForOwnTerm(template, term)];
  }

  final remaining =
      generateSchemeOfWork(template, lastConcludedTopicId, lastConcludedSubTopicId: lastConcludedSubTopicId);
  final windows = <List<SchemeOfWorkEntry>>[];
  var cursor = 0;
  for (var i = 0; i < template.terms.length; i++) {
    if (cursor >= remaining.length) {
      windows.add(const []);
      continue;
    }
    final end = (cursor + TermDates.teachingWeekCount).clamp(cursor, remaining.length);
    final slice = remaining.sublist(cursor, end);
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
