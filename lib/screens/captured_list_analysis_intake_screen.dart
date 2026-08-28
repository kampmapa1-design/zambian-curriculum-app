import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../models/syllabus_models.dart';
import '../services/handwritten_list_transcription_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import 'document_pages_capture_screen.dart';
import 'subject_grade_topic_picker_screen.dart';

/// "Analyze Results" → "Capture List On Paper?" — for a results list a
/// teacher already has on paper (handwritten OR typed), captured fresh
/// specifically to run Analysis on it, distinct from "Capture Manual
/// Scores" (which only produces an editable Word copy, no gender/marks
/// structure, and never feeds Analysis). This flow DOES need structured
/// data — gender and a numeric score per candidate — since that's what
/// Analysis computes grade bands and gender counts from, so it asks for
/// the minimum needed (subject/grade, a total-marks figure, gender per
/// row) rather than trying to infer it all from the photo alone.
///
/// Deliberately skips topic/sub-topic selection (unlike marking-scheme
/// creation) — a results list isn't tied to one topic — and skips
/// anything else not strictly needed, to keep this path short and
/// robust.
class CapturedListAnalysisIntakeScreen extends StatefulWidget {
  const CapturedListAnalysisIntakeScreen({super.key, this.schemeRepository, this.scriptRepository, this.transcriptionService});

  final MarkingSchemeRepository? schemeRepository;
  final MarkingScriptRepository? scriptRepository;
  final HandwrittenListTranscriptionService? transcriptionService;

  @override
  State<CapturedListAnalysisIntakeScreen> createState() => _CapturedListAnalysisIntakeScreenState();
}

class _RowEntry {
  final firstName = TextEditingController();
  final surname = TextEditingController();
  final score = TextEditingController();
  CandidateGender? gender;

  _RowEntry({String firstName = '', String surname = '', String score = ''}) {
    this.firstName.text = firstName;
    this.surname.text = surname;
    this.score.text = score;
  }

  void dispose() {
    firstName.dispose();
    surname.dispose();
    score.dispose();
  }
}

enum _Step { subjectGrade, details, capturing, review }

class _CapturedListAnalysisIntakeScreenState extends State<CapturedListAnalysisIntakeScreen> {
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final MarkingScriptRepository _scriptRepository = widget.scriptRepository ?? MarkingScriptRepository();
  late final HandwrittenListTranscriptionService _transcriptionService =
      widget.transcriptionService ?? HandwrittenListTranscriptionService();

  _Step _step = _Step.subjectGrade;
  SyllabusTemplate? _template;

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
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Results List — Subject & Grade', pickTopic: false),
      ),
    );
    if (!mounted) return;
    if (template == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _template = template;
      _titleController.text = '${template.subject.name} — ${template.grade.name} Results';
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
          title: 'Capture Results List',
          instructions: 'Photograph each page of the already-completed results list — handwritten or typed, '
              'any pattern.',
        ),
      ),
    );
    if (!mounted) return;
    if (pages == null || pages.isEmpty) {
      setState(() => _step = _Step.details);
      return;
    }

    setState(() => _transcribing = true);
    try {
      final table = await _transcriptionService.transcribe(pages);
      if (!mounted) return;
      setState(() {
        _rows
          ..clear()
          ..addAll(_rowsFrom(table));
        _aiNotes = table.notes;
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

  /// Best-effort mapping from a generic transcribed table into name/score
  /// starting points — a teacher reviews and corrects every row anyway
  /// (and sets gender, never guessed), so this only needs to save typing
  /// when it guesses right, never to be authoritative.
  List<_RowEntry> _rowsFrom(TranscribedTable table) {
    int? nameCol;
    int? scoreCol;
    for (var i = 0; i < table.headers.length; i++) {
      final h = table.headers[i].toLowerCase();
      if (nameCol == null && h.contains('name')) nameCol = i;
      if (scoreCol == null && (h.contains('score') || h.contains('mark') || h.contains('total'))) scoreCol = i;
    }

    return [
      for (final row in table.rows)
        _RowEntry(
          firstName: nameCol != null && nameCol < row.length ? _firstWord(row[nameCol]) : (row.isNotEmpty ? _firstWord(row[0]) : ''),
          surname: nameCol != null && nameCol < row.length
              ? _restWords(row[nameCol])
              : (row.isNotEmpty ? _restWords(row[0]) : ''),
          score: scoreCol != null && scoreCol < row.length
              ? row[scoreCol]
              : (row.length > 1 ? row[1] : ''),
        ),
    ];
  }

  String _firstWord(String s) => s.trim().split(RegExp(r'\s+')).firstOrNull ?? '';
  String _restWords(String s) {
    final parts = s.trim().split(RegExp(r'\s+'));
    return parts.length > 1 ? parts.sublist(1).join(' ') : '';
  }

  void _addRow() => setState(() => _rows.add(_RowEntry()));

  void _removeRow(int index) => setState(() {
        _rows[index].dispose();
        _rows.removeAt(index);
      });

  Future<void> _confirmAndAnalyze() async {
    if (_rows.isEmpty) return;
    final total = double.parse(_totalMarksController.text.trim());

    for (final row in _rows) {
      if (row.firstName.text.trim().isEmpty || row.surname.text.trim().isEmpty || row.gender == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Every row needs a first name, surname, and gender before analyzing.')),
        );
        return;
      }
      if (double.tryParse(row.score.text.trim()) == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${row.firstName.text} ${row.surname.text}" needs a numeric score.')),
        );
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final scheme = MarkingScheme(
        id: '${DateTime.now().millisecondsSinceEpoch}',
        title: _titleController.text.trim(),
        subjectName: _template!.subject.name,
        gradeName: _template!.grade.name,
        topicName: 'Captured Results List',
        questions: [
          MarkingSchemeQuestion(label: 'Total', expectedAnswerOrKeywords: '(from a captured results list)', maxMarks: total),
        ],
        createdAt: DateTime.now(),
      );
      await _schemeRepository.save(scheme);

      var nextNumber = await _scriptRepository.nextScriptNumber();
      for (final row in _rows) {
        final score = double.parse(row.score.text.trim());
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
              transcribedAnswer: '(from a captured results list)',
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save this results list: $error')));
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Capture List On Paper')),
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
                      Text('Reading the results list…'),
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
            '${_template!.subject.name} · ${_template!.grade.name}',
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
            label: const Text('Capture Results List'),
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
            'Review every row before analyzing — set gender for each, and correct anything the AI misread.',
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
              onPressed: _saving ? null : _confirmAndAnalyze,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.query_stats_outlined),
              label: Text(_saving ? 'Saving…' : 'Analyze ${_rows.length} Result(s)'),
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
