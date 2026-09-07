import 'package:flutter/material.dart';

import '../models/syllabus_models.dart';
import '../services/template_repository.dart';

/// Step 1 of "Select Own Topics Scheme" (see home_screen.dart's
/// `_openSelectOwnTopicsScheme` for the full flow this belongs to): picks a
/// SUBJECT only — not a specific grade/form — then loads and returns EVERY
/// bundled grade/form for that subject within one curriculum (sorted by
/// level), so the next screen ([SelectOwnTopicsScreen]) can offer topics
/// from the whole Grade 10–12 (OBC) or Form 1–4 (CBC) range for that
/// subject at once, per the real request this feature was built for: a
/// teacher winding down a final year picking specific topics to
/// review/re-teach from anywhere across the whole course, not just one
/// grade/term.
///
/// Deliberately a separate screen from [SubjectGradeTopicPickerScreen]
/// rather than a new mode on it — that screen's whole model is "resolve to
/// one specific grade (and, optionally, one term)"; this one's job is the
/// opposite (resolve to every grade for a subject at once), and keeping
/// them separate means neither screen's logic has to branch for the
/// other's shape.
class SelectOwnTopicsSubjectPickerScreen extends StatefulWidget {
  const SelectOwnTopicsSubjectPickerScreen({super.key, this.repository});

  final TemplateRepository? repository;

  @override
  State<SelectOwnTopicsSubjectPickerScreen> createState() => _SelectOwnTopicsSubjectPickerScreenState();
}

class _SelectOwnTopicsSubjectPickerScreenState extends State<SelectOwnTopicsSubjectPickerScreen> {
  late final TemplateRepository _repository = widget.repository ?? TemplateRepository();

  bool _loading = true;
  bool _loadingSubject = false;
  String? _error;
  List<TemplateManifestEntry> _manifest = [];

  /// Not-ready (non-real placeholder) files — see
  /// [TemplateRepository.hasRealSource]. Filtered out of every subject's
  /// own grade list below rather than shown as a disabled tile the way
  /// [SubjectGradeTopicPickerScreen] does: here a subject already stands
  /// for several grades at once, so a subject with at least one real grade
  /// should still work, just with its not-ready grade(s) simply absent
  /// from what gets offered.
  Set<String> _notReadyFiles = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _repository.ensureAllSeeded();
      final manifest = await _repository.loadManifest();
      final readiness = await Future.wait(manifest.map((e) => _repository.hasRealSource(e.file)));
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _notReadyFiles = {
          for (var i = 0; i < manifest.length; i++)
            if (!readiness[i]) manifest[i].file,
        };
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

  List<TemplateManifestEntry> get _cbcEntries => _manifest
      .where((e) => e.curriculumCode.toUpperCase().contains('CBC') && !_notReadyFiles.contains(e.file))
      .toList();

  List<TemplateManifestEntry> get _obcEntries => _manifest
      .where((e) => !e.curriculumCode.toUpperCase().contains('CBC') && !_notReadyFiles.contains(e.file))
      .toList();

  /// Grouped by curriculum+subject code (not just subject name) — a
  /// subject name alone isn't a safe key here since [_cbcEntries]/
  /// [_obcEntries] already separate by curriculum, but two DIFFERENT real
  /// subjects can still share a plain name loosely; the code is what
  /// [TemplateRepository.loadSyllabus] actually keys on.
  Map<String, List<TemplateManifestEntry>> _groupBySubject(List<TemplateManifestEntry> entries) {
    final bySubject = <String, List<TemplateManifestEntry>>{};
    for (final entry in entries) {
      bySubject.putIfAbsent('${entry.curriculumCode}|${entry.subjectCode}', () => []).add(entry);
    }
    for (final grades in bySubject.values) {
      grades.sort((a, b) => a.gradeLevel.compareTo(b.gradeLevel));
    }
    return bySubject;
  }

  Future<void> _onSubjectTap(List<TemplateManifestEntry> gradeEntries) async {
    setState(() => _loadingSubject = true);
    final templates = <SyllabusTemplate>[];
    for (final entry in gradeEntries) {
      final template = await _repository.loadSyllabus(
        curriculumCode: entry.curriculumCode,
        subjectCode: entry.subjectCode,
        gradeLevel: entry.gradeLevel,
      );
      if (template != null) templates.add(template);
    }
    if (!mounted) return;
    setState(() => _loadingSubject = false);
    if (templates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load this subject.')),
      );
      return;
    }
    Navigator.of(context).pop(templates);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Own Topics Scheme')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!)))
              : Stack(
                  children: [
                    _buildColumns(context),
                    if (_loadingSubject)
                      Container(
                        color: Colors.black26,
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10, left: 4, right: 4),
            child: Text(
              'Pick a subject, then pick any topics or sub-topics from anywhere across its whole '
              'range — handy for reviewing or re-teaching specific topics when winding down a '
              'final year.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _subjectColumn(context, 'CBC', cbcBySubject)),
              const SizedBox(width: 8),
              Expanded(child: _subjectColumn(context, 'OBC', obcBySubject)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _subjectColumn(BuildContext context, String heading, Map<String, List<TemplateManifestEntry>> bySubject) {
    final keys = bySubject.keys.toList()..sort((a, b) => bySubject[a]!.first.subjectName.compareTo(bySubject[b]!.first.subjectName));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            heading,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ),
        if (keys.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('No subjects yet', style: TextStyle(fontStyle: FontStyle.italic)),
          ),
        for (final key in keys)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              title: Text(bySubject[key]!.first.subjectName, style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(
                bySubject[key]!.map((e) => e.gradeName).join(', '),
                style: const TextStyle(fontSize: 10.5),
              ),
              onTap: _loadingSubject ? null : () => _onSubjectTap(bySubject[key]!),
            ),
          ),
      ],
    );
  }
}
