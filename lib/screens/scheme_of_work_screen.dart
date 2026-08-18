import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/progress_repository.dart';

/// Lets a teacher mark the last topic they concluded, then shows the
/// auto-generated scheme of work for what comes next — entirely from data
/// already on the device.
class SchemeOfWorkScreen extends StatefulWidget {
  const SchemeOfWorkScreen({super.key, required this.template, this.repository});

  final SyllabusTemplate template;

  /// Injectable for tests; defaults to a fresh [ProgressRepository].
  final ProgressRepository? repository;

  @override
  State<SchemeOfWorkScreen> createState() => _SchemeOfWorkScreenState();
}

class _SchemeOfWorkScreenState extends State<SchemeOfWorkScreen> {
  late final ProgressRepository _repository = widget.repository ?? ProgressRepository();

  bool _loading = true;
  int? _selectedTopicId;
  List<SchemeOfWorkEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lastConcluded = await _repository.getLastConcludedTopicId(
      subjectCode: widget.template.subject.code,
      gradeLevel: widget.template.grade.level,
    );
    if (!mounted) return;
    setState(() {
      _selectedTopicId = lastConcluded;
      _entries = generateSchemeOfWork(widget.template, lastConcluded);
      _loading = false;
    });
  }

  Future<void> _onTopicSelected(int topicId) async {
    setState(() {
      _selectedTopicId = topicId;
      _entries = generateSchemeOfWork(widget.template, topicId);
    });
    await _repository.markTopicConcluded(
      subjectCode: widget.template.subject.code,
      gradeLevel: widget.template.grade.level,
      topicId: topicId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.template.subject.name} · ${widget.template.grade.name}'),
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Last topic concluded', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Pick where you left off last term. The scheme of work below updates '
          'immediately and is saved on this device.',
        ),
        const SizedBox(height: 8),
        _ProgressPicker(
          template: widget.template,
          selectedTopicId: _selectedTopicId,
          onChanged: _onTopicSelected,
        ),
        const Divider(height: 32),
        Text('Next scheme of work', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_selectedTopicId == null)
          const Text('Mark a concluded topic above to generate the scheme.')
        else if (_entries.isEmpty)
          const Text('Every bundled topic for this subject and grade is already covered.')
        else
          for (final entry in _entries) _SchemeEntryCard(entry: entry),
      ],
    );
  }
}

class _ProgressPicker extends StatelessWidget {
  const _ProgressPicker({
    required this.template,
    required this.selectedTopicId,
    required this.onChanged,
  });

  final SyllabusTemplate template;
  final int? selectedTopicId;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final term in template.terms) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(term.name, style: Theme.of(context).textTheme.labelLarge),
            ),
          ),
          for (final topic in term.topics)
            RadioListTile<int>(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(topic.name),
              value: topic.id,
              groupValue: selectedTopicId,
              onChanged: (value) {
                if (value != null) onChanged(value);
              },
            ),
        ],
      ],
    );
  }
}

class _SchemeEntryCard extends StatelessWidget {
  const _SchemeEntryCard({required this.entry});

  final SchemeOfWorkEntry entry;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Week ${entry.weekNumber}', style: Theme.of(context).textTheme.labelMedium),
            Text(entry.title, style: Theme.of(context).textTheme.titleSmall),
            if (entry.objectives.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Objectives', style: Theme.of(context).textTheme.labelSmall),
              for (final o in entry.objectives) Text('•  ${o.description}'),
            ],
            if (entry.competencies.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Competencies', style: Theme.of(context).textTheme.labelSmall),
              for (final c in entry.competencies) Text('•  ${c.description}'),
            ],
          ],
        ),
      ),
    );
  }
}
