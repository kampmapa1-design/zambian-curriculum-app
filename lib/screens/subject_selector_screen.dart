import 'package:flutter/material.dart';

import '../models/syllabus_models.dart';
import '../services/template_repository.dart';
import 'scheme_of_work_screen.dart';

class SubjectSelectorScreen extends StatefulWidget {
  const SubjectSelectorScreen({super.key, this.repository});

  /// Injectable for tests; defaults to a fresh [TemplateRepository].
  final TemplateRepository? repository;

  @override
  State<SubjectSelectorScreen> createState() => _SubjectSelectorScreenState();
}

class _SubjectSelectorScreenState extends State<SubjectSelectorScreen> {
  late final TemplateRepository _repository = widget.repository ?? TemplateRepository();

  bool _seeding = true;
  bool _loadingSyllabus = false;
  String? _seedError;

  List<TemplateManifestEntry> _manifest = [];
  String? _selectedSubjectCode;
  int? _selectedGradeLevel;
  SyllabusTemplate? _template;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _repository.ensureAllSeeded();
      final manifest = await _repository.loadManifest();
      setState(() {
        _manifest = manifest;
        _seeding = false;
      });
    } catch (error) {
      setState(() {
        _seedError = error.toString();
        _seeding = false;
      });
    }
  }

  List<TemplateManifestEntry> get _subjectOptions {
    final seen = <String>{};
    final options = <TemplateManifestEntry>[];
    for (final entry in _manifest) {
      if (seen.add(entry.subjectCode)) options.add(entry);
    }
    options.sort((a, b) => a.subjectName.compareTo(b.subjectName));
    return options;
  }

  List<TemplateManifestEntry> get _gradeOptionsForSelectedSubject {
    if (_selectedSubjectCode == null) return const [];
    final options =
        _manifest.where((e) => e.subjectCode == _selectedSubjectCode).toList()
          ..sort((a, b) => a.gradeLevel.compareTo(b.gradeLevel));
    return options;
  }

  void _onSubjectChanged(String? code) {
    setState(() {
      _selectedSubjectCode = code;
      // Reset the grade if it no longer applies to the newly picked subject.
      final stillValid =
          _gradeOptionsForSelectedSubject.any((e) => e.gradeLevel == _selectedGradeLevel);
      if (!stillValid) _selectedGradeLevel = null;
      _template = null;
    });
    _maybeLoadTemplate();
  }

  void _onGradeChanged(int? level) {
    setState(() {
      _selectedGradeLevel = level;
      _template = null;
    });
    _maybeLoadTemplate();
  }

  Future<void> _maybeLoadTemplate() async {
    final subjectCode = _selectedSubjectCode;
    final gradeLevel = _selectedGradeLevel;
    if (subjectCode == null || gradeLevel == null) return;

    setState(() => _loadingSyllabus = true);
    final template =
        await _repository.loadSyllabus(subjectCode: subjectCode, gradeLevel: gradeLevel);
    if (!mounted) return;
    setState(() {
      _template = template;
      _loadingSyllabus = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subject Selector')),
      body: _seeding
          ? const Center(child: _LoadingIndicator(label: 'Loading bundled syllabi…'))
          : _seedError != null
              ? Center(child: Text('Could not load bundled syllabi:\n$_seedError'))
              : _buildContent(),
      floatingActionButton: _template == null
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.event_note),
              label: const Text('Plan next term'),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => SchemeOfWorkScreen(template: _template!)),
                );
              },
            ),
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Subject'),
                  value: _selectedSubjectCode,
                  items: _subjectOptions
                      .map((e) => DropdownMenuItem(value: e.subjectCode, child: Text(e.subjectName)))
                      .toList(),
                  onChanged: _onSubjectChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  decoration: const InputDecoration(labelText: 'Grade'),
                  value: _selectedGradeLevel,
                  items: _gradeOptionsForSelectedSubject
                      .map((e) => DropdownMenuItem(value: e.gradeLevel, child: Text(e.gradeName)))
                      .toList(),
                  onChanged: _selectedSubjectCode == null ? null : _onGradeChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: _buildSyllabusArea()),
        ],
      ),
    );
  }

  Widget _buildSyllabusArea() {
    if (_selectedSubjectCode == null || _selectedGradeLevel == null) {
      return const Center(child: Text('Pick a subject and grade to load its syllabus.'));
    }
    if (_loadingSyllabus) {
      return const Center(child: _LoadingIndicator(label: 'Loading syllabus…'));
    }
    if (_template == null) {
      return const Center(child: Text('No bundled syllabus for that combination yet.'));
    }
    return _SyllabusView(template: _template!);
  }
}

class _LoadingIndicator extends StatelessWidget {
  const _LoadingIndicator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text(label),
      ],
    );
  }
}

class _SyllabusView extends StatelessWidget {
  const _SyllabusView({required this.template});

  final SyllabusTemplate template;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: ValueKey('${template.subject.code}-${template.grade.level}'),
      children: [
        for (final term in template.terms)
          ExpansionTile(
            title: Text(term.name, style: Theme.of(context).textTheme.titleMedium),
            initiallyExpanded: true,
            children: [for (final topic in term.topics) _TopicTile(topic: topic)],
          ),
      ],
    );
  }
}

class _TopicTile extends StatelessWidget {
  const _TopicTile({required this.topic});

  final Topic topic;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: ExpansionTile(
        title: Text(topic.name),
        subtitle: topic.description == null ? null : Text(topic.description!),
        children: [
          if (topic.objectives.isNotEmpty)
            _BulletSection(title: 'Learning objectives', items: topic.objectives.map((o) => o.description)),
          if (topic.competencies.isNotEmpty)
            _BulletSection(title: 'Competencies', items: topic.competencies.map((c) => c.description)),
          for (final subTopic in topic.subTopics) _SubTopicTile(subTopic: subTopic),
        ],
      ),
    );
  }
}

class _SubTopicTile extends StatelessWidget {
  const _SubTopicTile({required this.subTopic});

  final SubTopic subTopic;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: ExpansionTile(
        title: Text(subTopic.name),
        subtitle: subTopic.description == null ? null : Text(subTopic.description!),
        children: [
          if (subTopic.objectives.isNotEmpty)
            _BulletSection(
                title: 'Learning objectives', items: subTopic.objectives.map((o) => o.description)),
          if (subTopic.competencies.isNotEmpty)
            _BulletSection(title: 'Competencies', items: subTopic.competencies.map((c) => c.description)),
        ],
      ),
    );
  }
}

class _BulletSection extends StatelessWidget {
  const _BulletSection({required this.title, required this.items});

  final String title;
  final Iterable<String> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('•  $item'),
            ),
        ],
      ),
    );
  }
}
