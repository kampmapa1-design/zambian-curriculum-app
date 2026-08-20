import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/lesson_plan.dart';
import '../services/custom_template_repository.dart';
import '../services/docx_heading_extractor.dart';

/// What one extracted heading maps to: either one of the app's known
/// auto-filled fields (populated from the syllabus at generation time, same
/// as the CDC default template), or a plain custom text field carrying the
/// heading's own label, or "ignore" to drop it entirely.
enum _MappingTarget {
  ignore('Ignore — don\'t include this section', null, null),
  subject('Auto-fill: Subject', 'subject', 'Subject'),
  topic('Auto-fill: Topic', 'topic', 'Topic'),
  subTopic('Auto-fill: Sub-topic', 'subTopic', 'Sub-topic'),
  generalCompetences('Auto-fill: General Competences', 'generalCompetences', 'General Competence(s)'),
  specificCompetences('Auto-fill: Specific Competences', 'specificCompetences', 'Specific Competences'),
  custom('Keep as its own field (you fill it in)', null, null);

  const _MappingTarget(this.label, this.fieldId, this.fieldLabel);
  final String label;
  final String? fieldId;
  final String? fieldLabel;
}

/// Stage 3: "Upload My Own Template" — picks a .docx file, extracts its
/// section headings, and lets the teacher map each one to an app field
/// (auto-filled from the syllabus) or keep it as a plain text field they
/// fill in by hand. The result is saved as a [LessonPlanTemplate] alongside
/// the bundled CDC default, selectable when generating a lesson plan.
class TemplateUploadScreen extends StatefulWidget {
  const TemplateUploadScreen({super.key, this.repository, this.extractor});

  final CustomTemplateRepository? repository;
  final DocxHeadingExtractor? extractor;

  @override
  State<TemplateUploadScreen> createState() => _TemplateUploadScreenState();
}

class _TemplateUploadScreenState extends State<TemplateUploadScreen> {
  late final CustomTemplateRepository _repository = widget.repository ?? CustomTemplateRepository();
  late final DocxHeadingExtractor _extractor = widget.extractor ?? DocxHeadingExtractor();

  String? _fileName;
  List<String> _headings = [];
  final Map<String, _MappingTarget> _mapping = {};
  final _nameController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['docx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        setState(() => _error = 'Could not read that file.');
        return;
      }
      final headings = _extractor.extractHeadings(bytes);
      if (headings.isEmpty) {
        setState(() => _error = 'No section headings were found in that document.');
        return;
      }
      setState(() {
        _fileName = file.name;
        _headings = headings;
        _mapping
          ..clear()
          ..addEntries(headings.map((h) => MapEntry(h, _MappingTarget.custom)));
        _nameController.text = file.name.replaceAll(RegExp(r'\.docx$', caseSensitive: false), '');
      });
    } catch (e) {
      setState(() => _error = 'Could not read that document: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _slugify(String text) {
    final slug = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return slug.isEmpty ? 'field' : slug;
  }

  Future<void> _save() async {
    final fields = <LessonPlanFieldDef>[];
    final usedIds = <String>{};
    for (final heading in _headings) {
      final target = _mapping[heading] ?? _MappingTarget.custom;
      if (target == _MappingTarget.ignore) continue;
      if (target == _MappingTarget.custom) {
        var id = _slugify(heading);
        while (!usedIds.add(id)) {
          id = '${id}_2';
        }
        fields.add(LessonPlanFieldDef(id: id, label: heading, type: LessonPlanFieldType.multiline));
      } else {
        usedIds.add(target.fieldId!);
        fields.add(LessonPlanFieldDef(
          id: target.fieldId!,
          label: target.fieldLabel!,
          type: LessonPlanFieldType.multiline,
          autoFilled: true,
        ));
      }
    }

    if (fields.isEmpty) {
      setState(() => _error = 'Map at least one heading to a field before saving.');
      return;
    }

    final name = _nameController.text.trim().isEmpty ? 'My Template' : _nameController.text.trim();
    final template = LessonPlanTemplate(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      source: 'Uploaded by you from "$_fileName" — a personal template, not a verified official CDC document.',
      sections: [LessonPlanSectionDef(id: 'custom', title: name, fields: fields)],
      progressionStages: const [],
    );

    setState(() => _busy = true);
    try {
      await _repository.save(template);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"$name" saved.')));
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upload My Own Template')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Pick a Word (.docx) template. Its section headings will be listed below so you can map '
            'each one to a field the app already knows how to fill in from the syllabus, or keep it as '
            'a plain field you fill in yourself. PDF templates aren\'t supported yet — .docx only for now.',
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickFile,
            icon: const Icon(Icons.upload_file),
            label: Text(_fileName == null ? 'Choose .docx file' : 'Chosen: $_fileName'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (_headings.isNotEmpty) ...[
            const SizedBox(height: 20),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Template name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            Text('Map each heading', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final heading in _headings) _buildMappingRow(heading),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save template'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMappingRow(String heading) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 2, child: Text(heading, overflow: TextOverflow.ellipsis, maxLines: 2)),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<_MappingTarget>(
              isExpanded: true,
              value: _mapping[heading],
              items: _MappingTarget.values
                  .map((t) => DropdownMenuItem(value: t, child: Text(t.label, overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _mapping[heading] = value);
              },
            ),
          ),
        ],
      ),
    );
  }
}
