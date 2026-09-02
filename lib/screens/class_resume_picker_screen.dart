import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/class_progress_repository.dart';
import 'term_topic_picker_screen.dart';

/// What a teacher decided for one class in [ClassResumePickerScreen]: the
/// class label they typed/picked, plus where the new scheme should resume
/// from — both null means "start this subject from the very beginning."
typedef ClassResumeSelection = ({String classLabel, int? topicId, int? subTopicId});

enum _ResumeChoice { useStored, override, beginning }

/// Scheme of Work generation's "get the right starting point" step — always
/// shown, every time, before a scheme is generated. Two questions, per this
/// app's own standing design: which class is this for, and where did that
/// class reach. Never silently trusts a stored progress cursor on its own —
/// see ClassProgressRepository's doc comment for why (a stored cursor is
/// only ever offered as a pre-filled suggestion here, confirmed or
/// overridden by the teacher every time, so a one-off scheme generated for
/// a colleague's class can never silently corrupt the teacher's own
/// regular class's real progress record).
class ClassResumePickerScreen extends StatefulWidget {
  const ClassResumePickerScreen({super.key, required this.template, this.repository});

  final SyllabusTemplate template;
  final ClassProgressRepository? repository;

  @override
  State<ClassResumePickerScreen> createState() => _ClassResumePickerScreenState();
}

class _ClassResumePickerScreenState extends State<ClassResumePickerScreen> {
  late final ClassProgressRepository _repository = widget.repository ?? ClassProgressRepository();
  final _classLabelController = TextEditingController();
  List<String> _knownLabels = const [];
  String? _lookedUpFor;
  ClassProgress? _storedProgress;
  bool _looking = false;
  _ResumeChoice? _choice;
  SchemeOfWorkEntry? _overrideEntry;

  @override
  void initState() {
    super.initState();
    _loadKnownLabels();
  }

  @override
  void dispose() {
    _classLabelController.dispose();
    super.dispose();
  }

  Future<void> _loadKnownLabels() async {
    final labels = await _repository.listClassLabels(
      curriculumCode: widget.template.curriculum.code,
      subjectCode: widget.template.subject.code,
      gradeLevel: widget.template.grade.level,
    );
    if (mounted) setState(() => _knownLabels = labels);
  }

  Future<void> _lookUp(String label) async {
    final trimmed = label.trim();
    if (trimmed.isEmpty || trimmed == _lookedUpFor) return;
    setState(() {
      _looking = true;
      _choice = null;
      _overrideEntry = null;
    });
    final progress = await _repository.getProgress(
      curriculumCode: widget.template.curriculum.code,
      subjectCode: widget.template.subject.code,
      gradeLevel: widget.template.grade.level,
      classLabel: trimmed,
    );
    if (!mounted) return;
    setState(() {
      _lookedUpFor = trimmed;
      _storedProgress = progress;
      _choice = progress != null ? _ResumeChoice.useStored : null;
      _looking = false;
    });
  }

  Future<void> _pickDifferentTopic() async {
    final entry = await Navigator.of(context).push<SchemeOfWorkEntry>(
      MaterialPageRoute(builder: (_) => TermTopicPickerScreen(template: widget.template)),
    );
    if (entry == null || !mounted) return;
    setState(() {
      _overrideEntry = entry;
      _choice = _ResumeChoice.override;
    });
  }

  bool get _hasLabel => _classLabelController.text.trim().isNotEmpty;

  bool get _canContinue {
    if (!_hasLabel || _lookedUpFor != _classLabelController.text.trim()) return false;
    if (_choice == _ResumeChoice.override) return _overrideEntry != null;
    return _choice != null;
  }

  void _continue() {
    final label = _classLabelController.text.trim();
    switch (_choice!) {
      case _ResumeChoice.useStored:
        Navigator.of(context).pop<ClassResumeSelection>(
          (classLabel: label, topicId: _storedProgress!.topicId, subTopicId: _storedProgress!.subTopicId),
        );
      case _ResumeChoice.override:
        Navigator.of(context).pop<ClassResumeSelection>(
          (classLabel: label, topicId: _overrideEntry!.topic.id, subTopicId: _overrideEntry!.subTopic?.id),
        );
      case _ResumeChoice.beginning:
        Navigator.of(context).pop<ClassResumeSelection>((classLabel: label, topicId: null, subTopicId: null));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Which Class, and Where Did It Reach?')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Text(
            'Two quick questions so this scheme starts at exactly the right topic — nothing retaught, '
            'nothing skipped, and a scheme you generate for someone else never affects your own class\'s '
            'record.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          Text('Which class is this for?', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'e.g. "Grade 10A", "my class", or "printing for Mr. Banda" — whatever tells you and future you '
            'apart from anyone else.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _classLabelController,
            decoration: const InputDecoration(labelText: 'Class', border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
            onSubmitted: _lookUp,
            onTapOutside: (_) => _lookUp(_classLabelController.text),
          ),
          if (_knownLabels.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final label in _knownLabels)
                  ActionChip(
                    label: Text(label),
                    onPressed: () {
                      _classLabelController.text = label;
                      _lookUp(label);
                    },
                  ),
              ],
            ),
          ],
          if (_hasLabel && _lookedUpFor != _classLabelController.text.trim() && !_looking) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _lookUp(_classLabelController.text),
              child: const Text('Check this class\'s progress'),
            ),
          ],
          if (_looking) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (_lookedUpFor != null && _lookedUpFor == _classLabelController.text.trim()) ...[
            const Divider(height: 32),
            Text('Where did this class reach?', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildResumeChoices(),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _canContinue ? _continue : null,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Continue'),
          ),
        ),
      ),
    );
  }

  Widget _buildResumeChoices() {
    final stored = _storedProgress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stored != null) ...[
          _ChoiceCard(
            selected: _choice == _ResumeChoice.useStored,
            title: 'Continue from where I last recorded this class',
            subtitle: _topicSummary(stored.topicId, stored.subTopicId),
            onTap: () => setState(() => _choice = _ResumeChoice.useStored),
          ),
          const SizedBox(height: 8),
        ] else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'No progress recorded yet for this class.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        _ChoiceCard(
          selected: _choice == _ResumeChoice.override,
          title: _overrideEntry != null ? 'Resume after: ${_overrideEntry!.title}' : 'Pick where it reached',
          subtitle: 'Choose the exact topic (or sub-topic) this class last covered.',
          onTap: _pickDifferentTopic,
        ),
        const SizedBox(height: 8),
        _ChoiceCard(
          selected: _choice == _ResumeChoice.beginning,
          title: 'Start this subject from the very beginning',
          subtitle: 'For a class that hasn\'t started this subject yet.',
          onTap: () => setState(() => _choice = _ResumeChoice.beginning),
        ),
      ],
    );
  }

  String _topicSummary(int topicId, int? subTopicId) {
    for (final term in widget.template.terms) {
      for (final topic in term.topics) {
        if (topic.id != topicId) continue;
        if (subTopicId == null) return topic.name;
        for (final subTopic in topic.subTopics) {
          if (subTopic.id == subTopicId) return '${topic.name} — ${subTopic.name}';
        }
        return topic.name;
      }
    }
    return 'Topic no longer in the syllabus — pick a new point below.';
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.selected, required this.title, required this.subtitle, required this.onTap});

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: selected ? colorScheme.primaryContainer : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
