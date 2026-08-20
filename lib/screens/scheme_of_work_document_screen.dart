import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scheme_of_work.dart';
import '../models/scheme_of_work_document.dart';
import '../models/syllabus_models.dart';
import '../services/scheme_of_work_document_service.dart';

/// Lets a teacher fill in the CDC scheme-of-work columns that aren't part of
/// the app's syllabus data (Prescribed Competences, Content/Concept,
/// Expected Standard, Strategies/Methods, Assessments, Material/Resources,
/// References) around the columns that already are (Week, Topic/Sub-topic,
/// Specific Competences, Learning Activities), then export the whole
/// generated scheme as PDF or Word and share it — entirely on-device.
class SchemeOfWorkDocumentScreen extends StatefulWidget {
  const SchemeOfWorkDocumentScreen({
    super.key,
    required this.template,
    required this.entries,
    this.documentService,
  });

  final SyllabusTemplate template;
  final List<SchemeOfWorkEntry> entries;
  final SchemeOfWorkDocumentService? documentService;

  @override
  State<SchemeOfWorkDocumentScreen> createState() => _SchemeOfWorkDocumentScreenState();
}

class _SchemeOfWorkDocumentScreenState extends State<SchemeOfWorkDocumentScreen> {
  late final SchemeOfWorkDocumentService _documentService =
      widget.documentService ?? SchemeOfWorkDocumentService();
  late SchemeOfWorkDocumentDraft _draft;
  final Map<String, TextEditingController> _controllers = {};
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _draft = SchemeOfWorkDocumentDraft.fromEntries(widget.entries);

    _controllers['schoolName'] = TextEditingController(text: _draft.header.schoolName);
    _controllers['teacherName'] = TextEditingController(text: _draft.header.teacherName);
    _controllers['year'] = TextEditingController(text: _draft.header.year);
    _controllers['philosophy'] = TextEditingController(text: _draft.header.curriculumPhilosophyAndGoals);

    for (var i = 0; i < _draft.rows.length; i++) {
      final row = _draft.rows[i];
      _controllers['row_${i}_prescribedCompetences'] = TextEditingController(text: row.prescribedCompetences);
      _controllers['row_${i}_contentConcept'] = TextEditingController(text: row.contentConcept);
      _controllers['row_${i}_expectedStandard'] = TextEditingController(text: row.expectedStandard);
      _controllers['row_${i}_strategiesMethods'] = TextEditingController(text: row.strategiesMethods);
      _controllers['row_${i}_assessments'] = TextEditingController(text: row.assessments);
      _controllers['row_${i}_materialResources'] = TextEditingController(text: row.materialResources);
      _controllers['row_${i}_references'] = TextEditingController(text: row.references);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _syncDraftFromControllers() {
    _draft = _draft.withHeader(SchemeOfWorkHeader(
      schoolName: _controllers['schoolName']!.text,
      teacherName: _controllers['teacherName']!.text,
      year: _controllers['year']!.text,
      curriculumPhilosophyAndGoals: _controllers['philosophy']!.text,
    ));
    for (var i = 0; i < _draft.rows.length; i++) {
      _draft = _draft.withRow(
        i,
        _draft.rows[i].copyWith(
          prescribedCompetences: _controllers['row_${i}_prescribedCompetences']!.text,
          contentConcept: _controllers['row_${i}_contentConcept']!.text,
          expectedStandard: _controllers['row_${i}_expectedStandard']!.text,
          strategiesMethods: _controllers['row_${i}_strategiesMethods']!.text,
          assessments: _controllers['row_${i}_assessments']!.text,
          materialResources: _controllers['row_${i}_materialResources']!.text,
          references: _controllers['row_${i}_references']!.text,
        ),
      );
    }
  }

  SchemeOfWorkDocumentContext get _context => SchemeOfWorkDocumentContext(
        subjectName: widget.template.subject.name,
        gradeName: widget.template.grade.name,
        curriculumName: widget.template.curriculum.name,
        termLabel: widget.entries.isEmpty ? '' : _termLabel(),
      );

  String _termLabel() {
    final termNames = <String>{};
    for (final term in widget.template.terms) {
      for (final topic in term.topics) {
        if (widget.entries.any((e) => e.topic.id == topic.id)) termNames.add(term.name);
      }
    }
    return termNames.join(', ');
  }

  Future<void> _export(bool asPdf) async {
    _syncDraftFromControllers();
    setState(() => _exporting = true);
    try {
      final file = asPdf
          ? await _documentService.generatePdf(_context, _draft)
          : await _documentService.generateDocx(_context, _draft);
      if (!mounted) return;
      // The OS share sheet is what actually surfaces WhatsApp, email,
      // Bluetooth, and every other installed share target — one call here
      // covers all of them rather than integrating each one separately.
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        subject: 'Scheme of Work — ${widget.template.subject.name} ${widget.template.grade.name}',
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the document: $error')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scheme of Work')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          Text(
            'CDC scheme-of-work layout. Week, Topic/Sub-topic, Specific Competences, and '
            'Learning Activities are filled in from the syllabus already on your device; '
            'fill in the remaining columns below before exporting.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 16),
          Text('Document details', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _textField('schoolName', 'Name of School'),
          _textField('teacherName', 'Name of Teacher'),
          _textField('year', 'Year', helper: 'e.g. 2026'),
          _textField('philosophy', 'Curriculum Philosophy and Goals',
              maxLines: 3, helper: 'Optional — shown once at the top of the document, not per week.'),
          const SizedBox(height: 16),
          for (var i = 0; i < _draft.rows.length; i++) _buildRowCard(i),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : () => _export(false),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Export Word'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _exporting ? null : () => _export(true),
                  icon: _exporting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Export PDF'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _textField(String controllerKey, String label, {int maxLines = 1, String? helper}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: _controllers[controllerKey],
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label, helperText: helper, border: const OutlineInputBorder()),
      ),
    );
  }

  Widget _buildRowCard(int index) {
    final row = _draft.rows[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        title: Text('Week ${row.entry.weekNumber} — ${row.entry.title}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (row.entry.competencies.isNotEmpty) ...[
            _readOnlyBlock('Specific Competences', row.entry.competencies.map((c) => c.description)),
            const SizedBox(height: 8),
          ],
          if (row.entry.objectives.isNotEmpty) ...[
            _readOnlyBlock('Learning Activities', row.entry.objectives.map((o) => o.description)),
            const SizedBox(height: 8),
          ],
          _textField('row_${index}_prescribedCompetences', 'Prescribed Competences', maxLines: 2),
          _textField('row_${index}_contentConcept', 'Content / Concept', maxLines: 3),
          _textField('row_${index}_expectedStandard', 'Expected Standard', maxLines: 2),
          _textField('row_${index}_strategiesMethods', 'Strategies / Methods', maxLines: 2),
          _textField('row_${index}_assessments', 'Assessments', maxLines: 2),
          _textField('row_${index}_materialResources', 'Material / Resources', maxLines: 2),
          _textField('row_${index}_references', 'References', maxLines: 2),
        ],
      ),
    );
  }

  Widget _readOnlyBlock(String label, Iterable<String> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        for (final item in items) Text('•  $item'),
      ],
    );
  }
}
