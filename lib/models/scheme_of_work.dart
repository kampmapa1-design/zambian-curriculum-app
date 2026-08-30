import 'syllabus_models.dart';

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

/// Builds the next stretch of a scheme of work: every topic/sub-topic that
/// comes strictly after [lastConcludedTopicId] in sequence, numbered as
/// consecutive weeks starting at 1.
///
/// Pass `null` for [lastConcludedTopicId] to generate a scheme from the very
/// first topic (e.g. a subject the teacher hasn't started yet). If the given
/// topic id isn't found in this template (stale progress from a template
/// that changed), the scheme also starts from the beginning rather than
/// silently omitting it.
List<SchemeOfWorkEntry> generateSchemeOfWork(
  SyllabusTemplate template,
  int? lastConcludedTopicId,
) {
  final topics = flattenTopics(template);
  if (topics.isEmpty) return const [];

  final concludedIndex =
      lastConcludedTopicId == null ? -1 : topics.indexWhere((t) => t.id == lastConcludedTopicId);
  final startIndex = concludedIndex + 1;
  if (startIndex >= topics.length) return const [];

  final entries = <SchemeOfWorkEntry>[];
  var week = 1;
  for (final topic in topics.sublist(startIndex)) {
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
