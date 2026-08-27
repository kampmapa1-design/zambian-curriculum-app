import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';

/// Picks a topic/sub-topic from an already-loaded [SyllabusTemplate],
/// organized as **Term → topics for that term's weeks** (matching the real
/// scheme of work) rather than one flat topic list — used by "Generate
/// Lesson Plan" once the subject and grade are already known, so a teacher
/// can drill down to exactly the topic (and week) they're about to teach.
/// Returns a [SchemeOfWorkEntry] via `Navigator.pop`, same shape as
/// [TopicPickerScreen] but grouped one level deeper.
class TermTopicPickerScreen extends StatelessWidget {
  const TermTopicPickerScreen({super.key, required this.template});

  final SyllabusTemplate template;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${template.subject.name} · ${template.grade.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final term in template.terms)
            ExpansionTile(
              title: Text(term.name, style: Theme.of(context).textTheme.titleMedium),
              initiallyExpanded: template.terms.length == 1,
              children: _entriesForTerm(context, term),
            ),
        ],
      ),
    );
  }

  List<Widget> _entriesForTerm(BuildContext context, Term term) {
    final allEntries = generateSchemeOfWork(template, null);
    final topicIdsInTerm = term.topics.map((t) => t.id).toSet();
    final termEntries = allEntries.where((e) => topicIdsInTerm.contains(e.topic.id)).toList();
    final byWeek = groupEntriesByRealWeek(termEntries);

    if (byWeek.isEmpty) {
      // No sourced week numbers for this subject yet — fall back to a plain
      // topic/sub-topic list, same structure TopicPickerScreen used.
      return [for (final topic in term.topics) _TopicTile(topic: topic)];
    }

    return [
      for (final weekEntry in byWeek.entries) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          child: Text('Week ${weekEntry.key}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
        ),
        for (final entry in weekEntry.value)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: ListTile(
              dense: true,
              title: Text(entry.title),
              onTap: () => Navigator.of(context).pop(entry),
            ),
          ),
      ],
    ];
  }
}

class _TopicTile extends StatelessWidget {
  const _TopicTile({required this.topic});

  final Topic topic;

  void _choose(BuildContext context, {SubTopic? subTopic}) {
    Navigator.of(context).pop(SchemeOfWorkEntry(
      weekNumber: 1,
      topic: topic,
      subTopic: subTopic,
      objectives: subTopic?.objectives ?? topic.objectives,
      competencies: subTopic?.competencies ?? topic.competencies,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (topic.subTopics.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(left: 12),
        child: ListTile(
          dense: true,
          title: Text(topic.name),
          onTap: () => _choose(context),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: ExpansionTile(
        title: Text(topic.name),
        children: [
          for (final subTopic in topic.subTopics)
            ListTile(
              dense: true,
              title: Text(subTopic.name),
              onTap: () => _choose(context, subTopic: subTopic),
            ),
        ],
      ),
    );
  }
}
