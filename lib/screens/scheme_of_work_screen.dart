import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/entitlement_service.dart';
import '../services/progress_repository.dart';
import 'teaching_notes_sheet.dart';

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
  GenerationAccessResult _access = const GenerationAccessResult(allowed: false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lastConcluded = await _repository.getLastConcludedTopicId(
      curriculumCode: widget.template.curriculum.code,
      subjectCode: widget.template.subject.code,
      gradeLevel: widget.template.grade.level,
    );
    final access = await EntitlementService.instance.checkGenerationAccess();
    if (!mounted) return;
    setState(() {
      _selectedTopicId = lastConcluded;
      _entries = generateSchemeOfWork(widget.template, lastConcluded);
      _access = access;
      _loading = false;
    });
  }

  Future<void> _onTopicSelected(int topicId) async {
    final access = await EntitlementService.instance.checkGenerationAccess();
    setState(() {
      _selectedTopicId = topicId;
      _entries = generateSchemeOfWork(widget.template, topicId);
      _access = access;
    });
    await _repository.markTopicConcluded(
      curriculumCode: widget.template.curriculum.code,
      subjectCode: widget.template.subject.code,
      gradeLevel: widget.template.grade.level,
      topicId: topicId,
    );
  }

  Future<void> _recheckAccess() async {
    final access = await EntitlementService.instance.checkGenerationAccess();
    if (!mounted) return;
    setState(() => _access = access);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.template.subject.name} · ${widget.template.grade.name}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              widget.template.curriculum.name,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ),
        ),
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
        else if (!_access.allowed)
          _AccessGate(message: _access.message!, onUnlocked: _recheckAccess)
        else if (_entries.isEmpty)
          const Text('Every bundled topic for this subject and grade is already covered.')
        else
          for (final entry in _entries) _SchemeEntryCard(entry: entry),
      ],
    );
  }
}

class _AccessGate extends StatefulWidget {
  const _AccessGate({required this.message, required this.onUnlocked});

  final String message;
  final VoidCallback onUnlocked;

  @override
  State<_AccessGate> createState() => _AccessGateState();
}

class _AccessGateState extends State<_AccessGate> {
  bool _busy = false;
  bool _online = true;

  @override
  void initState() {
    super.initState();
    _refreshConnectivity();
  }

  Future<void> _refreshConnectivity() async {
    final online = await EntitlementService.instance.isOnline;
    if (!mounted) return;
    setState(() => _online = online);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      widget.onUnlocked();
    } catch (_) {
      await _refreshConnectivity();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_online ? Icons.lock_outline : Icons.wifi_off, color: colorScheme.error),
                const SizedBox(width: 8),
                Expanded(child: Text(widget.message)),
              ],
            ),
            if (!_online) ...[
              const SizedBox(height: 8),
              Text(
                "Ads and purchases need an internet connection, so they're unavailable "
                'right now.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: !_online || _busy
                      ? null
                      : () => _run(EntitlementService.instance.watchRewardedAd),
                  child: const Text('Watch ad to unlock'),
                ),
                FilledButton(
                  onPressed: !_online || _busy
                      ? null
                      : () => _run(EntitlementService.instance.verifySubscription),
                  child: const Text('Subscribe'),
                ),
                if (_busy)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ],
        ),
      ),
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
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => showTeachingNotesSheet(
                  context,
                  topic: entry.topic.name,
                  subtopic: entry.subTopic?.name,
                  syllabusContext: _syllabusContext(entry),
                ),
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Teaching notes'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _syllabusContext(SchemeOfWorkEntry entry) {
    final lines = <String>[
      'Topic: ${entry.topic.name}',
      if (entry.topic.description != null) entry.topic.description!,
      if (entry.subTopic != null) 'Sub-topic: ${entry.subTopic!.name}',
      if (entry.subTopic?.description != null) entry.subTopic!.description!,
      for (final o in entry.objectives) 'Learning objective: ${o.description}',
      for (final c in entry.competencies) 'Competency: ${c.description}',
    ];
    return lines.join('\n');
  }
}
