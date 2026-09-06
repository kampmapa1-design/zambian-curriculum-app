import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/scheme_of_work_calendar_pacing.dart';

/// Picks a topic/sub-topic from an already-loaded [SyllabusTemplate],
/// organized as **Term → the topics/weeks a fresh Scheme of Work for that
/// term actually places there** — used by "Generate Lesson Plan" once the
/// subject and grade are already known, so a teacher can drill down to
/// exactly the topic (and week) they're about to teach.
///
/// Grouped by [schemeOfWorkTermWindows] (2026-09-06, was each topic's own
/// authored JSON term) — see that function's own doc comment for the real
/// reported mismatch this fixes: a term's Scheme of Work can legitimately
/// pull in a topic authored under a LATER term (see
/// generateSchemeOfWorkForTerm) to fill out that term's real teaching
/// weeks, so grouping by each topic's own authored term instead of by
/// where a generated Scheme of Work actually places it could show a topic
/// under a completely different term here than a teacher had just seen it
/// under in their generated Scheme of Work.
///
/// Returns a [SchemeOfWorkEntry] via `Navigator.pop`, same shape as
/// [TopicPickerScreen] but grouped one level deeper.
class TermTopicPickerScreen extends StatelessWidget {
  const TermTopicPickerScreen({super.key, required this.template});

  final SyllabusTemplate template;

  @override
  Widget build(BuildContext context) {
    final windows = schemeOfWorkTermWindows(template);
    return Scaffold(
      appBar: AppBar(title: Text('${template.subject.name} · ${template.grade.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (var i = 0; i < template.terms.length; i++)
            ExpansionTile(
              title: Text(template.terms[i].name, style: Theme.of(context).textTheme.titleMedium),
              initiallyExpanded: template.terms.length == 1,
              children: _entriesForWindow(context, i < windows.length ? windows[i] : const []),
            ),
        ],
      ),
    );
  }

  List<Widget> _entriesForWindow(BuildContext context, List<SchemeOfWorkEntry> windowEntries) {
    if (windowEntries.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.only(left: 12, top: 4, bottom: 4),
          child: Text('No topics left to place in this term.'),
        ),
      ];
    }

    // Same calendar pacing SchemeOfWorkDocumentDraft.fromEntries applies
    // before building the actual document, so a subject with no real
    // sourced week numbers (the common case) still groups these topics
    // under the exact same week numbers a generated Scheme of Work would
    // show, rather than falling back to a flat, unnumbered topic list.
    final paced = applyCalendarPacing(windowEntries);
    final byWeek = groupEntriesByEffectiveWeek(paced);

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
