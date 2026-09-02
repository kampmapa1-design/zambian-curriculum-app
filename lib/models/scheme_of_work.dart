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

  const SchemeOfWorkEntry({
    required this.weekNumber,
    required this.topic,
    this.subTopic,
    required this.objectives,
    required this.competencies,
  });

  String get title => subTopic == null ? topic.name : '${topic.name} — ${subTopic!.name}';

  /// The real teaching week from a sourced scheme of work, when known — see
  /// [SubTopic.weekNumber]. Null for content ingested before real week data
  /// was tracked; callers should fall back to [weekNumber] in that case.
  int? get realWeekNumber => subTopic?.weekNumber ?? topic.weekNumber;

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
/// exact order a generated scheme presents them.
List<SchemeOfWorkEntry> _allEntries(SyllabusTemplate template) {
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
  final allEntries = _allEntries(template);
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
