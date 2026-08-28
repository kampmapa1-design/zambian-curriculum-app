import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/class_list_transcription_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import 'document_pages_capture_screen.dart';
import 'subject_grade_topic_picker_screen.dart';
import 'term_topic_picker_screen.dart';

/// For teachers who mark scripts entirely by hand and keep a handwritten
/// class list (name + score) rather than using this app's AI grading
/// pipeline: photograph that list, review the AI's transcription (every
/// row editable, gender required per row since a class list rarely marks
/// it), and confirm to create a marking scheme (one "Total" question) plus
/// one already-[MarkingScriptStatus.reviewed] script per student — so
/// hand-marked classes still show up in Analysis and marksheet exports
/// alongside AI-graded ones.
class ClassListImportScreen extends StatefulWidget {
  const ClassListImportScreen({super.key, this.schemeRepository, this.scriptRepository, this.transcriptionService});

  final MarkingSchemeRepository? schemeRepository;
  final MarkingScriptRepository? scriptRepository;
  final ClassListTranscriptionService? transcriptionService;

  @override
  State<ClassListImportScreen> createState() => _ClassListImportScreenState();
}

class _RowEntry {
  final firstName = TextEditingController();
  final surname = TextEditingController();
  final score = TextEditingController();
  CandidateGender? gender;

  _RowEntry({required String firstName, required String surname, required double score}) {
    this.firstName.text = firstName;
    this.surname.text = surname;
    this.score.text = score == score.roundToDouble() ? score.toInt().toString() : score.toString();
  }

  void dispose() {
    firstName.dispose();
    surname.dispose();
    score.dispose();
  }
}

enum _Step { subjectGrade, details, capturing, review }

class _ClassListImportScreenState extends State<ClassListImportScreen> {
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final MarkingScriptRepository _scriptRepository = widget.scriptRepository ?? MarkingScriptRepository();
  late final ClassListTranscriptionService _transcriptionService =
      widget.transcriptionService ?? ClassListTranscriptionService();

  _Step _step = _Step.subjectGrade;
  SyllabusTemplate? _template;
  SchemeOfWorkEntry? _entry;

  final _titleController = TextEditingController();
  final _totalMarksController = TextEditingController();

  bool _transcribing = false;
  bool _saving = false;
  String? _aiNotes;
  final List<_RowEntry> _rows = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pickSubjectGrade());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _totalMarksController.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _pickSubjectGrade() async {
    final template = await Navigator.of(context).push<SyllabusTemplate>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Class List — Subject & Grade', pickTopic: false),
      ),
    );
    if (template == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;

    final entry = await Navigator.of(context).push<SchemeOfWorkEntry>(
      MaterialPageRoute(builder: (_) => TermTopicPickerScreen(template: template)),
    );
    if (entry == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    setState(() {
      _template = template;
      _entry = entry;
      _titleController.text = '${template.subject.name} — ${entry.subTopic?.name ?? entry.topic.name} Class List';
      _step = _Step.details;
    });
  }

  Future<void> _startCapture() async {
    final total = double.tryParse(_totalMarksController.text.trim());
    if (_titleController.text.trim().isEmpty || total == null || total <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give this list a title and a total marks value greater than zero.')),
      );
      return;
    }

    setState(() => _step = _Step.capturing);
    final pages = await Navigator.of(context).push<List<File>>(
      MaterialPageRoute(
        builder: (_) => const DocumentPagesCaptureScreen(
          title: 'Capture Class List',
          instructions: "Photograph each page of the handwritten class list — one row per student, name and score.",
        ),
      ),
    );
    if (pages == null || pages.isEmpty) {
      if (mounted) setState(() => _step = _Step.details);
      return;
    }
    if (!mounted) return;

    setState(() => _transcribing = true);
    try {
      final transcribed = await _transcriptionService.transcribe(pages);
      if (!mounted) return;
      setState(() {
        _rows
          ..clear()
          ..addAll([
            for (final e in transcribed.entries)
              _RowEntry(firstName: e.firstName, surname: e.surname, score: e.score),
          ]);
        _aiNotes = transcribed.notes;
        _step = _Step.review;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not transcribe this list: $error')));
      setState(() => _step = _Step.details);
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  void _addRow() => setState(() => _rows.add(_RowEntry(firstName: '', surname: '', score: 0)));

  void _removeRow(int index) => setState(() {
        _rows[index].dispose();
        _rows.removeAt(index);
      });

  Future<void> _confirmAndSave() async {
    if (_rows.isEmpty) return;
    final total = double.parse(_totalMarksController.text.trim());

    for (final row in _rows) {
      if (row.firstName.text.trim().isEmpty || row.surname.text.trim().isEmpty || row.gender == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Every row needs a first name, surname, and gender before saving.')),
        );
        return;
      }
    }

    final alphabetical = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Arrange list in alphabetical order?'),
        content: const Text(
          'Yes sorts every marksheet export (PDF/Word/Excel) by surname. No keeps the order the rows are '
          'in above — the order they were captured/transcribed in.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Yes')),
        ],
      ),
    );
    if (!mounted || alphabetical == null) return;

    setState(() => _saving = true);
    try {
      final scheme = MarkingScheme(
        id: '${DateTime.now().millisecondsSinceEpoch}',
        title: _titleController.text.trim(),
        subjectName: _template!.subject.name,
        gradeName: _template!.grade.name,
        topicName: _entry!.topic.name,
        subTopicName: _entry!.subTopic?.name,
        questions: [
          MarkingSchemeQuestion(label: 'Total', expectedAnswerOrKeywords: '(hand-marked by teacher)', maxMarks: total),
        ],
        createdAt: DateTime.now(),
        preserveScriptOrder: !alphabetical,
      );
      await _schemeRepository.save(scheme);

      var nextNumber = await _scriptRepository.nextScriptNumber();
      for (final row in _rows) {
        final score = double.tryParse(row.score.text.trim()) ?? 0;
        final script = MarkingScript(
          id: '${DateTime.now().millisecondsSinceEpoch}_${nextNumber}_${row.surname.text.trim().toLowerCase()}',
          firstName: row.firstName.text.trim(),
          surname: row.surname.text.trim(),
          gender: row.gender!,
          scriptNumber: nextNumber,
          subjectName: _template!.subject.name,
          gradeName: _template!.grade.name,
          pageFileNames: const [],
          capturedAt: DateTime.now(),
          status: MarkingScriptStatus.reviewed,
          schemeId: scheme.id,
          gradedAnswers: [
            GradedAnswer(
              questionLabel: 'Total',
              maxMarks: total,
              transcribedAnswer: '(hand-marked by teacher, transcribed from a class list)',
              marksAwarded: score.clamp(0, total),
              confidence: MarkingConfidence.medium,
            ),
          ],
        );
        await _scriptRepository.add(script);
        nextNumber++;
      }

      if (!mounted) return;
      Navigator.of(context).pop<MarkingScheme>(scheme);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save this class list: $error')));
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import Handwritten Class List')),
      body: switch (_step) {
        _Step.subjectGrade => const Center(child: CircularProgressIndicator()),
        _Step.details => _buildDetailsForm(context),
        _Step.capturing => Center(
            child: _transcribing
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Reading the class list…'),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        _Step.review => _buildReview(context),
      },
    );
  }

  Widget _buildDetailsForm(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_template!.subject.name} · ${_template!.grade.name} · ${_entry!.subTopic?.name ?? _entry!.topic.name}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'List title', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _totalMarksController,
            decoration: const InputDecoration(
              labelText: 'Total possible marks for this assessment',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _startCapture,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Capture Class List'),
          ),
        ],
      ),
    );
  }

  Widget _buildReview(BuildContext context) {
    return Column(
      children: [
        if (_aiNotes case final notes? when notes.trim().isNotEmpty)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.tertiaryContainer,
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.auto_awesome_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(notes, style: Theme.of(context).textTheme.bodySmall)),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Review every row before saving — set gender for each, and correct anything the AI misread.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [
              for (var i = 0; i < _rows.length; i++) _buildRowCard(context, i),
              OutlinedButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add),
                label: const Text('Add Row'),
              ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _saving ? null : _confirmAndSave,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(_saving ? 'Saving…' : 'Confirm & Save ${_rows.length} Student(s)'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRowCard(BuildContext context, int index) {
    final row = _rows[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: row.firstName,
                    decoration: const InputDecoration(labelText: 'First name', isDense: true, border: OutlineInputBorder()),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: row.surname,
                    decoration: const InputDecoration(labelText: 'Surname', isDense: true, border: OutlineInputBorder()),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove row',
                  onPressed: () => _removeRow(index),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: row.score,
                    decoration: const InputDecoration(labelText: 'Score', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SegmentedButton<CandidateGender>(
                    segments: const [
                      ButtonSegment(value: CandidateGender.male, label: Text('Male')),
                      ButtonSegment(value: CandidateGender.female, label: Text('Female')),
                    ],
                    selected: {if (row.gender != null) row.gender!},
                    emptySelectionAllowed: true,
                    onSelectionChanged: (s) => setState(() => row.gender = s.firstOrNull),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
