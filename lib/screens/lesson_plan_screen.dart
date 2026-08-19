import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/lesson_plan.dart';
import '../models/scheme_of_work.dart';
import '../services/lesson_plan_document_service.dart';

/// Lets a teacher fill in the CDC lesson plan template for one scheme-of-work
/// entry (topic/sub-topic already known from the syllabus), then export it
/// as PDF or Word and share it — entirely on-device, no network required.
class LessonPlanScreen extends StatefulWidget {
  const LessonPlanScreen({
    super.key,
    required this.subjectName,
    required this.entry,
    this.template = defaultCdcLessonPlanTemplate,
    this.documentService,
  });

  final String subjectName;
  final SchemeOfWorkEntry entry;
  final LessonPlanTemplate template;
  final LessonPlanDocumentService? documentService;

  @override
  State<LessonPlanScreen> createState() => _LessonPlanScreenState();
}

class _LessonPlanScreenState extends State<LessonPlanScreen> {
  late final LessonPlanDocumentService _documentService = widget.documentService ?? LessonPlanDocumentService();
  late LessonPlanDraft _draft;
  final Map<String, TextEditingController> _controllers = {};
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _draft = LessonPlanDraft.empty(widget.template).withValue('subject', widget.subjectName).withValue(
          'topic',
          widget.entry.topic.name,
        );
    if (widget.entry.subTopic != null) {
      _draft = _draft.withValue('subTopic', widget.entry.subTopic!.name);
    }
    final generalCompetences = widget.entry.topic.competencies.map((c) => c.description).join('\n');
    if (generalCompetences.isNotEmpty) {
      _draft = _draft.withValue('generalCompetences', generalCompetences);
    }
    final specificCompetences = widget.entry.competencies.map((c) => c.description).join('\n');
    if (specificCompetences.isNotEmpty) {
      _draft = _draft.withValue('specificCompetences', specificCompetences);
    }
    if (widget.entry.objectives.isNotEmpty) {
      _draft = _draft.withValue('expectedStandard', widget.entry.objectives.first.description);
    }

    for (final field in widget.template.allFields) {
      _controllers[field.id] = TextEditingController(text: _draft.value(field.id));
    }
    for (var i = 0; i < _draft.progression.length; i++) {
      final row = _draft.progression[i];
      _controllers['progression_${i}_duration'] = TextEditingController(text: row.durationMinutes);
      _controllers['progression_${i}_teacher'] = TextEditingController(text: row.teacherRole);
      _controllers['progression_${i}_learners'] = TextEditingController(text: row.learnersRole);
      _controllers['progression_${i}_assessment'] = TextEditingController(text: row.assessmentCriteria);
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
    for (final field in widget.template.allFields) {
      _draft = _draft.withValue(field.id, _controllers[field.id]!.text);
    }
    for (var i = 0; i < _draft.progression.length; i++) {
      _draft = _draft.withProgressionRow(
        i,
        _draft.progression[i].copyWith(
          durationMinutes: _controllers['progression_${i}_duration']!.text,
          teacherRole: _controllers['progression_${i}_teacher']!.text,
          learnersRole: _controllers['progression_${i}_learners']!.text,
          assessmentCriteria: _controllers['progression_${i}_assessment']!.text,
        ),
      );
    }
  }

  Future<void> _export(bool asPdf) async {
    _syncDraftFromControllers();
    setState(() => _exporting = true);
    try {
      final file = asPdf
          ? await _documentService.generatePdf(widget.template, _draft)
          : await _documentService.generateDocx(widget.template, _draft);
      if (!mounted) return;
      // The OS share sheet is what actually surfaces WhatsApp, email,
      // Bluetooth, and every other installed share target — one call here
      // covers all of them rather than integrating each one separately.
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Lesson Plan — ${widget.entry.topic.name}',
      );
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
      appBar: AppBar(title: Text('Lesson Plan — ${widget.entry.title}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          Text(
            'Based on: ${widget.template.source}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 16),
          for (final section in widget.template.sections) ...[
            Text(section.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final field in section.fields) _buildField(field),
            const SizedBox(height: 16),
          ],
          Text('Lesson Progression', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Fixed stage order from the CDC template — filled in per stage below.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _draft.progression.length; i++) _buildProgressionCard(i),
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

  Widget _buildField(LessonPlanFieldDef field) {
    if (field.autoFilled) {
      final value = _controllers[field.id]!.text;
      if (value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: RichText(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style,
            children: [
              TextSpan(text: '${field.label}: ', style: const TextStyle(fontWeight: FontWeight.bold)),
              TextSpan(text: value),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: _controllers[field.id],
        maxLines: field.type == LessonPlanFieldType.multiline ? 4 : 1,
        decoration: InputDecoration(
          labelText: field.required ? '${field.label} *' : field.label,
          helperText: field.helpText,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildProgressionCard(int index) {
    final stage = _draft.progression[index].stage;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(stage, style: Theme.of(context).textTheme.titleSmall),
                ),
                SizedBox(
                  width: 110,
                  child: TextFormField(
                    controller: _controllers['progression_${index}_duration'],
                    decoration: const InputDecoration(labelText: 'Duration', isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controllers['progression_${index}_teacher'],
              maxLines: 3,
              decoration: const InputDecoration(labelText: "Teacher's Role", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controllers['progression_${index}_learners'],
              maxLines: 3,
              decoration: const InputDecoration(labelText: "Learners' Role", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controllers['progression_${index}_assessment'],
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Assessment Criteria', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
    );
  }
}
