import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/marking_scheme.dart';
import '../services/marking_scheme_repository.dart';

/// AI-Assisted Marking, Stage 3 — the marking scheme editor. A teacher
/// defines each question, its expected answer/keywords, and its mark
/// allocation; saved once, reused across every script from the same
/// assessment (Stage 4 onward sends this alongside each script's page
/// images to the AI provider).
///
/// Always reached already linked to a real subject/grade/topic from the
/// app's syllabus data — [subjectName]/[gradeName]/[topicName] are
/// required, not free text a teacher could type any name into (see
/// startCreateMarkingScheme, which does that picking before this screen
/// ever opens).
class MarkingSchemeBuilderScreen extends StatefulWidget {
  const MarkingSchemeBuilderScreen({
    super.key,
    required this.subjectName,
    required this.gradeName,
    required this.topicName,
    this.subTopicName,
    this.existing,
    this.repository,
  });

  final String subjectName;
  final String gradeName;
  final String topicName;
  final String? subTopicName;

  /// Non-null when editing an already-saved scheme.
  final MarkingScheme? existing;
  final MarkingSchemeRepository? repository;

  @override
  State<MarkingSchemeBuilderScreen> createState() => _MarkingSchemeBuilderScreenState();
}

class _RowControllers {
  final label = TextEditingController();
  final answer = TextEditingController();
  final marks = TextEditingController();

  _RowControllers();

  _RowControllers.from(MarkingSchemeQuestion q) {
    label.text = q.label;
    answer.text = q.expectedAnswerOrKeywords;
    marks.text = q.maxMarks == q.maxMarks.roundToDouble() ? q.maxMarks.toInt().toString() : q.maxMarks.toString();
  }

  void dispose() {
    label.dispose();
    answer.dispose();
    marks.dispose();
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
    setState(() => _rows.add(_RowControllers()..label.text = 'Q${_rows.length + 1}'));
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
    final scheme = MarkingScheme(
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
          ),
      ],
      createdAt: widget.existing?.createdAt ?? DateTime.now(),
    );
    final saved = await _repository.save(scheme);
    if (!mounted) return;
    Navigator.of(context).pop<MarkingScheme>(saved);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New Marking Scheme' : 'Edit Marking Scheme')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
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
          ],
        ),
      ),
    );
  }
}
