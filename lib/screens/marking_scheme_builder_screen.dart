import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/marking_scheme.dart';
import '../services/marking_key_generation_service.dart';
import '../services/marking_scheme_repository.dart';
import 'marking_scheme_paper_structure_screen.dart';

/// AI-Assisted Marking, Stage 3 — the marking scheme editor. A teacher
/// defines each question, its expected answer/keywords, and its mark
/// allocation; saved once, reused across every script from the same
/// assessment (Stage 4 onward sends this alongside each script's page
/// images to the AI provider).
///
/// [subjectName]/[gradeName]/[topicName] are required strings, but their
/// source varies by caller: the marking-key upload flow
/// (marking_key_upload_flow.dart) collects them as plain manual text
/// entry (subject name / level / type of exam — a full mock exam or past
/// paper doesn't map to one bundled syllabus topic), not picked from the
/// app's syllabus data.
class MarkingSchemeBuilderScreen extends StatefulWidget {
  const MarkingSchemeBuilderScreen({
    super.key,
    required this.subjectName,
    required this.gradeName,
    required this.topicName,
    this.subTopicName,
    this.existing,
    this.initialQuestions,
    this.aiNotes,
    this.aiDetectedSections = const [],
    this.repository,
  });

  final String subjectName;
  final String gradeName;
  final String topicName;
  final String? subTopicName;

  /// Non-null when editing an already-saved scheme.
  final MarkingScheme? existing;

  /// Stage B — pre-fills a NEW scheme's rows from an AI-generated draft
  /// (see MarkingKeyGenerationService) without treating it as "editing an
  /// existing scheme" the way [existing] does: title stays "New", and a
  /// review banner shows [aiNotes]. Ignored if [existing] is set.
  final List<MarkingSchemeQuestion>? initialQuestions;
  final String? aiNotes;

  /// The AI's own detected section headings + real answer-instructions
  /// (see MarkingKeyGenerationService), carried through to
  /// MarkingSchemePaperStructureScreen on save as a hint — empty for
  /// manual entry or a scheme with no detected sections.
  final List<DerivedMarkingKeySection> aiDetectedSections;

  final MarkingSchemeRepository? repository;

  @override
  State<MarkingSchemeBuilderScreen> createState() => _MarkingSchemeBuilderScreenState();
}

class _RowControllers {
  final label = TextEditingController();
  final answer = TextEditingController();
  final marks = TextEditingController();
  final section = TextEditingController();

  _RowControllers();

  _RowControllers.from(MarkingSchemeQuestion q) {
    label.text = q.label;
    answer.text = q.expectedAnswerOrKeywords;
    marks.text = q.maxMarks == q.maxMarks.roundToDouble() ? q.maxMarks.toInt().toString() : q.maxMarks.toString();
    section.text = q.sectionName ?? '';
  }

  void dispose() {
    label.dispose();
    answer.dispose();
    marks.dispose();
    section.dispose();
  }
}

class _MarkingSchemeBuilderScreenState extends State<MarkingSchemeBuilderScreen> {
  late final MarkingSchemeRepository _repository = widget.repository ?? MarkingSchemeRepository();
  late final TextEditingController _titleController;
  final List<_RowControllers> _rows = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _titleController = TextEditingController(
      text: existing?.title ??
          '${widget.subjectName} — ${widget.subTopicName ?? widget.topicName} Assessment',
    );
    if (existing != null && existing.questions.isNotEmpty) {
      _rows.addAll(existing.questions.map(_RowControllers.from));
    } else if (widget.initialQuestions case final initial? when initial.isNotEmpty) {
      _rows.addAll(initial.map(_RowControllers.from));
    } else {
      _addRow();
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _addRow() {
    setState(() => _rows.add(_RowControllers()
      ..label.text = 'Q${_rows.length + 1}'
      // Consecutive questions are usually in the same section as the one
      // before them — a convenience default, not a guess about content.
      ..section.text = _rows.isNotEmpty ? _rows.last.section.text : ''));
  }

  void _removeRow(int index) {
    setState(() {
      _rows[index].dispose();
      _rows.removeAt(index);
    });
  }

  double get _totalMarks {
    var total = 0.0;
    for (final r in _rows) {
      total += double.tryParse(r.marks.text.trim()) ?? 0;
    }
    return total;
  }

  bool get _canSave =>
      _titleController.text.trim().isNotEmpty &&
      _rows.isNotEmpty &&
      _rows.every((r) => r.label.text.trim().isNotEmpty && (double.tryParse(r.marks.text.trim()) ?? 0) > 0);

  Future<void> _save() async {
    if (!_canSave) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give every question a label and a mark allocation greater than zero.')),
      );
      return;
    }
    setState(() => _saving = true);
    final draft = MarkingScheme(
      id: widget.existing?.id ?? '${DateTime.now().millisecondsSinceEpoch}',
      title: _titleController.text.trim(),
      subjectName: widget.subjectName,
      gradeName: widget.gradeName,
      topicName: widget.topicName,
      subTopicName: widget.subTopicName,
      questions: [
        for (final r in _rows)
          MarkingSchemeQuestion(
            label: r.label.text.trim(),
            expectedAnswerOrKeywords: r.answer.text.trim(),
            maxMarks: double.parse(r.marks.text.trim()),
            sectionName: r.section.text.trim().isEmpty ? null : r.section.text.trim(),
          ),
      ],
      createdAt: widget.existing?.createdAt ?? DateTime.now(),
      preserveScriptOrder: widget.existing?.preserveScriptOrder ?? false,
    );

    if (!mounted) return;
    // Always routed through here before persisting — see that screen's own
    // doc comment for why a flat sum of every listed question can be the
    // wrong total for a paper with an "answer N of M" structure.
    final confirmed = await Navigator.of(context).push<MarkingScheme>(
      MaterialPageRoute(
        builder: (_) => MarkingSchemePaperStructureScreen(draft: draft, derivedSections: widget.aiDetectedSections),
      ),
    );
    if (confirmed == null) {
      // Teacher backed out of the confirmation step entirely (not "Skip",
      // which returns the draft unchanged) — stay on the builder rather
      // than silently discarding their edits.
      if (mounted) setState(() => _saving = false);
      return;
    }

    final saved = await _repository.save(confirmed);
    if (!mounted) return;
    Navigator.of(context).pop<MarkingScheme>(saved);
  }

  @override
  Widget build(BuildContext context) {
    final isAiDraft = widget.existing == null && (widget.initialQuestions?.isNotEmpty ?? false);
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New Marking Scheme' : 'Edit Marking Scheme')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (isAiDraft)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'AI-suggested from the uploaded question paper — review every answer and mark '
                          'allocation below before saving. Nothing here is final until you do.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                  if (widget.aiNotes case final notes? when notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(notes, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
          Text(
            '${widget.subjectName} · ${widget.gradeName} · ${widget.subTopicName ?? widget.topicName}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Scheme title', border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Questions', style: Theme.of(context).textTheme.titleMedium),
              Text('Total: ${_totalMarks.toStringAsFixed(_totalMarks == _totalMarks.roundToDouble() ? 0 : 1)} marks'),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _rows.length; i++) _buildQuestionCard(i),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addRow,
            icon: const Icon(Icons.add),
            label: const Text('Add Question'),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving…' : 'Save Scheme'),
          ),
        ),
      ),
    );
  }

  Widget _buildQuestionCard(int index) {
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
                  flex: 2,
                  child: TextField(
                    controller: row.label,
                    decoration: const InputDecoration(labelText: 'Question', border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: row.marks,
                    decoration: const InputDecoration(labelText: 'Marks', border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove question',
                  onPressed: _rows.length > 1 ? () => _removeRow(index) : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: row.answer,
              decoration: const InputDecoration(
                labelText: 'Expected answer / keywords',
                hintText: 'e.g. mitochondria, powerhouse of the cell, ATP production',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: row.section,
              decoration: const InputDecoration(
                labelText: 'Section (optional)',
                hintText: 'e.g. Section A — leave blank if this paper has no sections',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
