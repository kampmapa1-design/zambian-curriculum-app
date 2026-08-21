import 'package:flutter/material.dart';

import '../models/syllabus_models.dart';
import '../services/template_repository.dart';

/// Picks a curriculum + subject + grade and returns the loaded
/// [SyllabusTemplate] via `Navigator.pop`. Shared entry point for every
/// "Generate ..." function on the Home screen — Lesson Plan, Scheme of
/// Work, and Teaching Notes all need this same context before they can do
/// anything, so it's one screen instead of three near-duplicates.
class CurriculumGradePickerScreen extends StatefulWidget {
  const CurriculumGradePickerScreen({super.key, required this.title, this.repository});

  final String title;
  final TemplateRepository? repository;

  @override
  State<CurriculumGradePickerScreen> createState() => _CurriculumGradePickerScreenState();
}

class _CurriculumGradePickerScreenState extends State<CurriculumGradePickerScreen> {
  late final TemplateRepository _repository = widget.repository ?? TemplateRepository();

  bool _loading = true;
  bool _loadingSyllabus = false;
  String? _error;
  List<TemplateManifestEntry> _manifest = [];
  String _curriculumCode = 'CBC_2023';
  String? _selectedSubjectCode;
  int? _selectedGradeLevel;

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
        if (_curricula.isNotEmpty && !_curricula.any((c) => c.code == _curriculumCode)) {
          _curriculumCode = _curricula.first.code;
        }
        _loading = false;
      });
    } catch (error) {
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  List<({String code, String name})> get _curricula {
    final seen = <String>{};
    final result = <({String code, String name})>[];
    for (final entry in _manifest) {
      if (seen.add(entry.curriculumCode)) {
        result.add((code: entry.curriculumCode, name: entry.curriculumName));
      }
    }
    return result;
  }

  List<TemplateManifestEntry> get _manifestForCurriculum =>
      _manifest.where((e) => e.curriculumCode == _curriculumCode).toList();

  List<TemplateManifestEntry> get _subjectOptions {
    final seen = <String>{};
    final options = <TemplateManifestEntry>[];
    for (final entry in _manifestForCurriculum) {
      if (seen.add(entry.subjectCode)) options.add(entry);
    }
    options.sort((a, b) => a.subjectName.compareTo(b.subjectName));
    return options;
  }

  List<TemplateManifestEntry> get _gradeOptionsForSelectedSubject {
    if (_selectedSubjectCode == null) return const [];
    final options =
        _manifestForCurriculum.where((e) => e.subjectCode == _selectedSubjectCode).toList()
          ..sort((a, b) => a.gradeLevel.compareTo(b.gradeLevel));
    return options;
  }

  void _onCurriculumChanged(String code) {
    if (code == _curriculumCode) return;
    setState(() {
      _curriculumCode = code;
      _selectedSubjectCode = null;
      _selectedGradeLevel = null;
    });
  }

  void _onSubjectChanged(String? code) {
    setState(() {
      _selectedSubjectCode = code;
      final stillValid = _gradeOptionsForSelectedSubject.any((e) => e.gradeLevel == _selectedGradeLevel);
      if (!stillValid) _selectedGradeLevel = null;
    });
  }

  Future<void> _confirm() async {
    final subjectCode = _selectedSubjectCode;
    final gradeLevel = _selectedGradeLevel;
    if (subjectCode == null || gradeLevel == null) return;

    setState(() => _loadingSyllabus = true);
    final template = await _repository.loadSyllabus(
      curriculumCode: _curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
    );
    if (!mounted) return;
    setState(() => _loadingSyllabus = false);
    if (template != null) {
      Navigator.of(context).pop(template);
    } else {
      setState(() => _error = 'No bundled syllabus for that combination yet.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_curricula.length > 1) ...[
                    SegmentedButton<String>(
                      segments: [
                        for (final c in _curricula)
                          ButtonSegment(value: c.code, label: Text(c.name, overflow: TextOverflow.ellipsis)),
                      ],
                      selected: {_curriculumCode},
                      onSelectionChanged: (s) => _onCurriculumChanged(s.first),
                    ),
                    const SizedBox(height: 16),
                  ],
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(labelText: 'Subject', border: OutlineInputBorder()),
                    value: _selectedSubjectCode,
                    items: _subjectOptions
                        .map((e) => DropdownMenuItem(value: e.subjectCode, child: Text(e.subjectName)))
                        .toList(),
                    onChanged: _onSubjectChanged,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    decoration: const InputDecoration(labelText: 'Grade', border: OutlineInputBorder()),
                    value: _selectedGradeLevel,
                    items: _gradeOptionsForSelectedSubject
                        .map((e) => DropdownMenuItem(value: e.gradeLevel, child: Text(e.gradeName)))
                        .toList(),
                    onChanged: _selectedSubjectCode == null
                        ? null
                        : (v) => setState(() => _selectedGradeLevel = v),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _selectedSubjectCode == null || _selectedGradeLevel == null || _loadingSyllabus
                        ? null
                        : _confirm,
                    child: _loadingSyllabus
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Continue'),
                  ),
                ],
              ),
            ),
    );
  }
}
