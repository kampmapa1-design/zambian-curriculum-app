import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';

/// Picks a topic or sub-topic from an already-loaded [SyllabusTemplate] and
/// returns it as a [SchemeOfWorkEntry] (week number isn't meaningful outside
/// a generated scheme, so it's fixed at 1) via `Navigator.pop`. Used
/// wherever a function needs "which topic" without already generating a
/// full scheme of work — Teaching Notes' standalone entry point, and Lesson
/// Plan's fallback when there's no clear "next topic" to jump to
/// automatically.
class TopicPickerScreen extends StatelessWidget {
  const TopicPickerScreen({super.key, required this.template});

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
              initiallyExpanded: true,
              children: [for (final topic in term.topics) _TopicTile(topic: topic)],
            ),
        ],
      ),
    );
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
              title: Text(subTopic.name),
              onTap: () => _choose(context, subTopic: subTopic),
            ),
        ],
      ),
    );
  }
}
