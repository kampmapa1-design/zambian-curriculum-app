import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';

/// One topic or sub-topic a teacher can pick, plus which of the (possibly
/// several) loaded grade/form templates it came from — needed because
/// [Topic]/[SubTopic] carry no back-reference to their own template, and
/// this screen deliberately lets picks span every grade/form of one
/// subject at once (see [SelectOwnTopicsSubjectPickerScreen]).
class _SelectableItem {
  const _SelectableItem({required this.template, required this.term, required this.entry});

  final SyllabusTemplate template;
  final Term term;
  final SchemeOfWorkEntry entry;

  /// Stable identity for this pick regardless of which other grades are
  /// also loaded — a topic id (or topic+sub-topic id pair) is already a
  /// real, unique local-database id (see database_helper.dart), but
  /// prefixing with the grade code costs nothing and removes any doubt.
  String get key => '${template.grade.code}|${entry.topic.id}|${entry.subTopic?.id}';

  String get title => entry.title;
}

/// Step 2 of "Select Own Topics Scheme": lets a teacher tick ANY topic or
/// sub-topic from ANY of [templates] (every grade/form of one subject,
/// already loaded by [SelectOwnTopicsSubjectPickerScreen]) — including by
/// typing its topic/sub-topic number (e.g. "1.7" or "10.2.4") into the
/// filter field, since every bundled topic/sub-topic name already starts
/// with its real syllabus numbering. Picks are kept in the order they were
/// made (a [LinkedHashMap]-backed [Map]), which is what ends up driving the
/// generated scheme's own week order — reviewable and reorderable on the
/// "Review selection" screen before building.
///
/// This is always a one-off (see [SchemeOfWorkDocumentScreen.classLabel]'s
/// own doc comment): picks can legitimately span several real grades/
/// forms/terms at once, which has no single real class progress record to
/// attach to — exactly the "review/re-teach specific topics when winding
/// down a final year" use case this was built for, not a normal term-by-
/// term class schedule.
class SelectOwnTopicsScreen extends StatefulWidget {
  const SelectOwnTopicsScreen({super.key, required this.templates});

  final List<SyllabusTemplate> templates;

  @override
  State<SelectOwnTopicsScreen> createState() => _SelectOwnTopicsScreenState();
}

class _SelectOwnTopicsScreenState extends State<SelectOwnTopicsScreen> {
  final Map<String, _SelectableItem> _selected = {};
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  late final List<_SelectableItem> _allItems = _buildItems(widget.templates);

  /// Mirrors [allSchemeOfWorkEntries]'s own eligibility rule (a topic is
  /// its own selectable item when it carries content directly or has no
  /// sub-topics of its own; every sub-topic is always its own item too) —
  /// duplicated here, deliberately, rather than called directly, since
  /// this also needs each item's own [Term] for grouping, which that
  /// function's flattened output doesn't carry.
  List<_SelectableItem> _buildItems(List<SyllabusTemplate> templates) {
    final items = <_SelectableItem>[];
    for (final template in templates) {
      for (final term in template.terms) {
        for (final topic in term.topics) {
          final hasOwnContent = topic.objectives.isNotEmpty || topic.competencies.isNotEmpty;
          if (hasOwnContent || topic.subTopics.isEmpty) {
            items.add(_SelectableItem(
              template: template,
              term: term,
              entry: SchemeOfWorkEntry(
                weekNumber: 0,
                topic: topic,
                objectives: topic.objectives,
                competencies: topic.competencies,
              ),
            ));
          }
          for (final subTopic in topic.subTopics) {
            items.add(_SelectableItem(
              template: template,
              term: term,
              entry: SchemeOfWorkEntry(
                weekNumber: 0,
                topic: topic,
                subTopic: subTopic,
                objectives: subTopic.objectives,
                competencies: subTopic.competencies,
              ),
            ));
          }
        }
      }
    }
    return items;
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _toggle(_SelectableItem item, bool? checked) {
    setState(() {
      if (checked ?? false) {
        _selected[item.key] = item;
      } else {
        _selected.remove(item.key);
      }
    });
  }

  Future<void> _openReview() async {
    final built = await Navigator.of(context).push<List<SchemeOfWorkEntry>>(
      MaterialPageRoute(
        builder: (_) => _SelectOwnTopicsReviewScreen(items: _selected.values.toList()),
      ),
    );
    if (built == null || !mounted) return;
    Navigator.of(context).pop(built);
  }

  @override
  Widget build(BuildContext context) {
    final subjectName = widget.templates.isNotEmpty ? widget.templates.first.subject.name : '';
    final filtered = _filter.trim().isEmpty
        ? null
        : _allItems.where((i) => i.title.toLowerCase().contains(_filter.trim().toLowerCase())).toList();

    return Scaffold(
      appBar: AppBar(title: Text('Select Own Topics — $subjectName')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _filterController,
              decoration: InputDecoration(
                labelText: 'Jump to a topic/sub-topic by name or number',
                helperText: 'e.g. "1.7" or "10.2.4" — matches any bundled topic starting with it',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _filter.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _filterController.clear();
                          setState(() => _filter = '');
                        },
                      ),
              ),
              onChanged: (value) => setState(() => _filter = value),
            ),
          ),
          Expanded(
            child: filtered != null ? _buildFlatList(filtered) : _buildGroupedTree(),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _selected.isEmpty ? null : _openReview,
            icon: const Icon(Icons.playlist_add_check),
            label: Text(_selected.isEmpty ? 'Pick at least one topic' : 'Review selection (${_selected.length})'),
          ),
        ),
      ),
    );
  }

  Widget _buildFlatList(List<_SelectableItem> items) {
    if (items.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('No matching topic/sub-topic.')));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return CheckboxListTile(
          dense: true,
          value: _selected.containsKey(item.key),
          onChanged: (checked) => _toggle(item, checked),
          title: Text(item.title),
          subtitle: Text('${item.template.grade.name} · ${item.term.name}', style: const TextStyle(fontSize: 11)),
        );
      },
    );
  }

  Widget _buildGroupedTree() {
    final sortedTemplates = [...widget.templates]..sort((a, b) => a.grade.level.compareTo(b.grade.level));
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      children: [
        for (final template in sortedTemplates)
          ExpansionTile(
            title: Text(template.grade.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            initiallyExpanded: sortedTemplates.length == 1,
            children: [
              for (final term in template.terms)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: ExpansionTile(
                    title: Text(term.name, style: const TextStyle(fontSize: 13)),
                    children: [
                      for (final item in _allItems.where((i) => i.template == template && i.term == term))
                        CheckboxListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.only(left: 16),
                          value: _selected.containsKey(item.key),
                          onChanged: (checked) => _toggle(item, checked),
                          title: Text(item.title, style: const TextStyle(fontSize: 13)),
                        ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Final review step: shows every pick in the order it was made, letting a
/// teacher drop any of them or reorder before "Build Scheme of Work" turns
/// the list into real, numbered [SchemeOfWorkEntry] rows (see
/// [SchemeOfWorkDocumentScreen]) — the same document screen every other
/// Scheme of Work path already ends at, so PDF/Word export, AI enrichment
/// of any thin row, and the related-marking-keys section all keep working
/// unchanged.
class _SelectOwnTopicsReviewScreen extends StatefulWidget {
  const _SelectOwnTopicsReviewScreen({required this.items});

  final List<_SelectableItem> items;

  @override
  State<_SelectOwnTopicsReviewScreen> createState() => _SelectOwnTopicsReviewScreenState();
}

class _SelectOwnTopicsReviewScreenState extends State<_SelectOwnTopicsReviewScreen> {
  late final List<_SelectableItem> _ordered = [...widget.items];

  void _remove(int index) => setState(() => _ordered.removeAt(index));

  // onReorderItem (not the deprecated onReorder) — its own newIndex already
  // accounts for the removed item at oldIndex, so no manual adjustment here.
  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _ordered.removeAt(oldIndex);
      _ordered.insert(newIndex, item);
    });
  }

  void _build() {
    // realWeekTrusted: false on every entry — these picks can span several
    // real terms/grades, each with its own real sourced week numbers that
    // mean nothing on THIS document's own calendar (the teacher's own pick
    // order is what matters here) — see applyCalendarPacing's own doc
    // comment on exactly this "numbers from two different terms" case,
    // which this deliberately forces every time rather than leaving it to
    // that function's own (real-week-number-based) heuristic to detect.
    final entries = [
      for (var i = 0; i < _ordered.length; i++)
        SchemeOfWorkEntry(
          weekNumber: i + 1,
          topic: _ordered[i].entry.topic,
          subTopic: _ordered[i].entry.subTopic,
          objectives: _ordered[i].entry.objectives,
          competencies: _ordered[i].entry.competencies,
          realWeekTrusted: false,
        ),
    ];
    Navigator.of(context).pop(entries);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review selection')),
      body: _ordered.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('Nothing left selected.')))
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
              itemCount: _ordered.length,
              onReorderItem: _reorder,
              itemBuilder: (context, index) {
                final item = _ordered[index];
                return Card(
                  key: ValueKey(item.key),
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    leading: CircleAvatar(radius: 12, child: Text('${index + 1}', style: const TextStyle(fontSize: 11))),
                    title: Text(item.title, style: const TextStyle(fontSize: 13)),
                    subtitle: Text('${item.template.grade.name} · ${item.term.name}', style: const TextStyle(fontSize: 10.5)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Remove',
                      onPressed: () => _remove(index),
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _ordered.isEmpty ? null : _build,
            icon: const Icon(Icons.event_note_outlined),
            label: Text('Build Scheme of Work (${_ordered.length} topics)'),
          ),
        ),
      ),
    );
  }
}
