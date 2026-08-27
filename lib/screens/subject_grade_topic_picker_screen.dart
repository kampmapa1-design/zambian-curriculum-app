import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/template_repository.dart';

/// Returned by [SubjectGradeTopicPickerScreen] when [SubjectGradeTopicPickerScreen.pickTerm] is true.
typedef TermSelection = ({SyllabusTemplate template, Term term});

/// Replaces the old dropdown-based subject/grade pickers with a single
/// clickable two-column list — CBC subjects on the left, OBC subjects on
/// the right — matching how teachers already think about the two curricula
/// side by side. Tapping a subject expands its grades/forms; tapping a
/// grade/form does one of three things depending on which mode is active
/// (exactly one of [pickTopic]/[pickTerm] should be true, or neither for
/// the plain subject+grade case):
/// - Neither set: returns the loaded [SyllabusTemplate] directly.
/// - [pickTerm]: expands into that grade's terms (Term 1/2/3) so one term
///   can be picked — used by "Generate Scheme of Work", which generates
///   for exactly one term at a time.
/// - [pickTopic]: expands further into topics/sub-topics so a single one
///   can be picked and returned as a [SchemeOfWorkEntry] — used by
///   "Generate Teaching Notes & Slides" and "Generate Lesson Plan".
class SubjectGradeTopicPickerScreen extends StatefulWidget {
  const SubjectGradeTopicPickerScreen({
    super.key,
    required this.title,
    required this.pickTopic,
    this.pickTerm = false,
    this.repository,
  });

  final String title;
  final bool pickTopic;
  final bool pickTerm;
  final TemplateRepository? repository;

  @override
  State<SubjectGradeTopicPickerScreen> createState() => _SubjectGradeTopicPickerScreenState();
}

class _SubjectGradeTopicPickerScreenState extends State<SubjectGradeTopicPickerScreen> {
  late final TemplateRepository _repository = widget.repository ?? TemplateRepository();

  bool _loading = true;
  String? _error;
  List<TemplateManifestEntry> _manifest = [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _repository.ensureAllSeeded();
      final manifest = await _repository.loadManifest();
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  /// CBC subjects go left, everything else (OBC, and any future curriculum
  /// that isn't CBC) goes right.
  List<TemplateManifestEntry> get _cbcEntries =>
      _manifest.where((e) => e.curriculumCode.toUpperCase().contains('CBC')).toList();

  List<TemplateManifestEntry> get _obcEntries =>
      _manifest.where((e) => !e.curriculumCode.toUpperCase().contains('CBC')).toList();

  Map<String, List<TemplateManifestEntry>> _groupBySubject(List<TemplateManifestEntry> entries) {
    final bySubject = <String, List<TemplateManifestEntry>>{};
    for (final entry in entries) {
      bySubject.putIfAbsent(entry.subjectName, () => []).add(entry);
    }
    for (final grades in bySubject.values) {
      grades.sort((a, b) => a.gradeLevel.compareTo(b.gradeLevel));
    }
    return bySubject;
  }

  void _onTemplateReady(SyllabusTemplate template) {
    Navigator.of(context).pop(template);
  }

  void _onTopicSelected(SchemeOfWorkEntry entry) {
    Navigator.of(context).pop(entry);
  }

  void _onTermSelected(SyllabusTemplate template, Term term) {
    Navigator.of(context).pop((template: template, term: term));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!)))
              : _buildColumns(context),
    );
  }

  Widget _buildColumns(BuildContext context) {
    final cbcBySubject = _groupBySubject(_cbcEntries);
    final obcBySubject = _groupBySubject(_obcEntries);

    if (cbcBySubject.isEmpty && obcBySubject.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('No subjects bundled yet.')));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _CurriculumColumn(
              heading: 'CBC',
              bySubject: cbcBySubject,
              pickTopic: widget.pickTopic,
              pickTerm: widget.pickTerm,
              repository: _repository,
              onTemplateReady: _onTemplateReady,
              onTopicSelected: _onTopicSelected,
              onTermSelected: _onTermSelected,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _CurriculumColumn(
              heading: 'OBC',
              bySubject: obcBySubject,
              pickTopic: widget.pickTopic,
              pickTerm: widget.pickTerm,
              repository: _repository,
              onTemplateReady: _onTemplateReady,
              onTopicSelected: _onTopicSelected,
              onTermSelected: _onTermSelected,
            ),
          ),
        ],
      ),
    );
  }
}

class _CurriculumColumn extends StatelessWidget {
  const _CurriculumColumn({
    required this.heading,
    required this.bySubject,
    required this.pickTopic,
    required this.pickTerm,
    required this.repository,
    required this.onTemplateReady,
    required this.onTopicSelected,
    required this.onTermSelected,
  });

  final String heading;
  final Map<String, List<TemplateManifestEntry>> bySubject;
  final bool pickTopic;
  final bool pickTerm;
  final TemplateRepository repository;
  final ValueChanged<SyllabusTemplate> onTemplateReady;
  final ValueChanged<SchemeOfWorkEntry> onTopicSelected;
  final void Function(SyllabusTemplate template, Term term) onTermSelected;

  @override
  Widget build(BuildContext context) {
    final subjectNames = bySubject.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            heading,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
          ),
        ),
        if (subjectNames.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('No subjects yet', style: TextStyle(fontStyle: FontStyle.italic)),
          ),
        for (final subjectName in subjectNames)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(subjectName, style: const TextStyle(fontSize: 13.5), overflow: TextOverflow.ellipsis),
                children: [
                  for (final entry in bySubject[subjectName]!)
                    _GradeTile(
                      entry: entry,
                      pickTopic: pickTopic,
                      pickTerm: pickTerm,
                      repository: repository,
                      onTemplateReady: onTemplateReady,
                      onTopicSelected: onTopicSelected,
                      onTermSelected: onTermSelected,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _GradeTile extends StatefulWidget {
  const _GradeTile({
    required this.entry,
    required this.pickTopic,
    required this.pickTerm,
    required this.repository,
    required this.onTemplateReady,
    required this.onTopicSelected,
    required this.onTermSelected,
  });

  final TemplateManifestEntry entry;
  final bool pickTopic;
  final bool pickTerm;
  final TemplateRepository repository;
  final ValueChanged<SyllabusTemplate> onTemplateReady;
  final ValueChanged<SchemeOfWorkEntry> onTopicSelected;
  final void Function(SyllabusTemplate template, Term term) onTermSelected;

  @override
  State<_GradeTile> createState() => _GradeTileState();
}

class _GradeTileState extends State<_GradeTile> {
  bool _loading = false;
  SyllabusTemplate? _template;

  Future<SyllabusTemplate?> _load() async {
    setState(() => _loading = true);
    final template = await widget.repository.loadSyllabus(
      curriculumCode: widget.entry.curriculumCode,
      subjectCode: widget.entry.subjectCode,
      gradeLevel: widget.entry.gradeLevel,
    );
    if (mounted) setState(() => _loading = false);
    return template;
  }

  Future<void> _onTap() async {
    final template = await _load();
    if (template != null) widget.onTemplateReady(template);
  }

  Future<void> _onExpand(bool expanding) async {
    if (!expanding || _template != null) return;
    final template = await _load();
    if (mounted) setState(() => _template = template);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.pickTopic && !widget.pickTerm) {
      return ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 24, right: 8),
        title: Text(widget.entry.gradeName, style: const TextStyle(fontSize: 13)),
        trailing: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null,
        onTap: _loading ? null : _onTap,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.only(left: 12, right: 8),
          title: Text(widget.entry.gradeName, style: const TextStyle(fontSize: 13)),
          onExpansionChanged: _onExpand,
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_template == null)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No bundled syllabus for this grade yet.'),
              )
            else if (widget.pickTerm)
              for (final term in _template!.terms)
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(term.name, style: const TextStyle(fontSize: 12.5)),
                    onTap: () => widget.onTermSelected(_template!, term),
                  ),
                )
            else
              for (final term in _template!.terms)
                for (final topic in term.topics) _TopicTile(topic: topic, onSelected: widget.onTopicSelected),
          ],
        ),
      ),
    );
  }
}

class _TopicTile extends StatelessWidget {
  const _TopicTile({required this.topic, required this.onSelected});

  final Topic topic;
  final ValueChanged<SchemeOfWorkEntry> onSelected;

  void _choose({SubTopic? subTopic}) {
    onSelected(SchemeOfWorkEntry(
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
        padding: const EdgeInsets.only(left: 16),
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(topic.name, style: const TextStyle(fontSize: 12.5)),
          onTap: () => _choose(),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(topic.name, style: const TextStyle(fontSize: 12.5)),
          children: [
            for (final subTopic in topic.subTopics)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(subTopic.name, style: const TextStyle(fontSize: 12)),
                  onTap: () => _choose(subTopic: subTopic),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
