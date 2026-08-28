import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/marking_script_repository.dart';

/// AI-Assisted Marking, Stage 6 — the review screen. Every AI-graded
/// answer (Stage 4) is shown next to the page it came from, fully
/// editable: a teacher can accept, adjust the mark, or correct the
/// transcription per question. Nothing here is final until the teacher
/// explicitly confirms (see [_confirmAndFinish]) — reachable only for
/// scripts already in [MarkingScriptStatus.graded] or
/// [MarkingScriptStatus.reviewed] (see MarkingQueueScreen._openScript).
class MarkingReviewScreen extends StatefulWidget {
  const MarkingReviewScreen({super.key, required this.script, required this.scheme, this.repository});

  final MarkingScript script;

  /// Null if the scheme was later deleted — review still works (editing
  /// against whatever [GradedAnswer.maxMarks] was captured at grading
  /// time), it just can't show the original expected-answer text.
  final MarkingScheme? scheme;

  final MarkingScriptRepository? repository;

  @override
  State<MarkingReviewScreen> createState() => _MarkingReviewScreenState();
}

class _AnswerControllers {
  final answer = TextEditingController();
  final marks = TextEditingController();
  MarkingConfidence confidence;
  final double maxMarks;
  final String questionLabel;

  _AnswerControllers(GradedAnswer a)
      : confidence = a.confidence,
        maxMarks = a.maxMarks,
        questionLabel = a.questionLabel {
    answer.text = a.transcribedAnswer;
    marks.text = a.marksAwarded == a.marksAwarded.roundToDouble()
        ? a.marksAwarded.toInt().toString()
        : a.marksAwarded.toString();
  }

  bool changedFrom(GradedAnswer original) =>
      answer.text.trim() != original.transcribedAnswer.trim() ||
      (double.tryParse(marks.text.trim()) ?? original.marksAwarded) != original.marksAwarded;

  void dispose() {
    answer.dispose();
    marks.dispose();
  }
}

class _MarkingReviewScreenState extends State<MarkingReviewScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final List<_AnswerControllers> _rows;
  List<File> _pageFiles = [];
  bool _loadingPages = true;
  bool _saving = false;
  int _viewerIndex = 0;

  @override
  void initState() {
    super.initState();
    _rows = [for (final a in widget.script.gradedAnswers ?? const <GradedAnswer>[]) _AnswerControllers(a)];
    _loadPages();
  }

  Future<void> _loadPages() async {
    final files = await _repository.pageFilesFor(widget.script);
    if (!mounted) return;
    setState(() {
      _pageFiles = files;
      _loadingPages = false;
    });
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  /// Matches exactly what [_confirmAndFinish] will actually save (same
  /// parse-or-zero, same clamp to [maxMarks]) so what's shown while
  /// editing never drifts from what gets recorded — an unparseable or
  /// out-of-range entry is clamped/zeroed the same way here as at save
  /// time, not just silently at the last moment.
  double _awardedFor(_AnswerControllers r) =>
      (double.tryParse(r.marks.text.trim()) ?? 0).clamp(0, r.maxMarks);

  double get _totalAwarded {
    var total = 0.0;
    for (final r in _rows) {
      total += _awardedFor(r);
    }
    return total;
  }

  double get _totalPossible => _rows.fold(0, (sum, r) => sum + r.maxMarks);

  Future<void> _confirmAndFinish() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Mark this script as Final?'),
        content: Text(
          '${widget.script.studentName} will be recorded with a final total of '
          '${_totalAwarded.toStringAsFixed(_totalAwarded == _totalAwarded.roundToDouble() ? 0 : 1)} / '
          '${_totalPossible.toStringAsFixed(_totalPossible == _totalPossible.roundToDouble() ? 0 : 1)}. '
          "You've reviewed every answer, including any you edited.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Confirm & Finish')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    final originalAnswers = widget.script.gradedAnswers ?? const <GradedAnswer>[];
    final updatedAnswers = [
      for (var i = 0; i < _rows.length; i++)
        GradedAnswer(
          questionLabel: _rows[i].questionLabel,
          maxMarks: _rows[i].maxMarks,
          transcribedAnswer: _rows[i].answer.text.trim(),
          marksAwarded: _awardedFor(_rows[i]),
          confidence: _rows[i].confidence,
          teacherEdited: i < originalAnswers.length ? _rows[i].changedFrom(originalAnswers[i]) : true,
        ),
    ];

    final updated = widget.script.copyWith(status: MarkingScriptStatus.reviewed, gradedAnswers: updatedAnswers);
    await _repository.update(updated);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final alreadyFinal = widget.script.status == MarkingScriptStatus.reviewed;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.script.studentName} — Script ${widget.script.scriptNumber}'),
      ),
      body: _loadingPages
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_pageFiles.isNotEmpty) _buildPageViewer(context),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                    children: [
                      if (alreadyFinal)
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.check_circle_outline, size: 18),
                              SizedBox(width: 8),
                              Expanded(child: Text('This script was already marked Reviewed/Final. Editing here re-confirms it.')),
                            ],
                          ),
                        ),
                      for (var i = 0; i < _rows.length; i++) _buildAnswerCard(context, i),
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Total: ${_totalAwarded.toStringAsFixed(_totalAwarded == _totalAwarded.roundToDouble() ? 0 : 1)} / '
                  '${_totalPossible.toStringAsFixed(_totalPossible == _totalPossible.roundToDouble() ? 0 : 1)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              FilledButton.icon(
                onPressed: _saving ? null : _confirmAndFinish,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(_saving ? 'Saving…' : 'Confirm & Finish'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageViewer(BuildContext context) {
    return Container(
      height: 220,
      color: Colors.black,
      child: Stack(
        children: [
          PageView.builder(
            itemCount: _pageFiles.length,
            onPageChanged: (i) => setState(() => _viewerIndex = i),
            itemBuilder: (context, i) => InteractiveViewer(
              child: Image.file(_pageFiles[i], fit: BoxFit.contain, width: double.infinity),
            ),
          ),
          Positioned(
            bottom: 8,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
              child: Text(
                'Page ${_viewerIndex + 1} of ${_pageFiles.length}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Warns a teacher, right on the field, whenever what's typed won't be
  /// saved as-is — an empty/unparseable entry is about to become 0, and an
  /// over-max entry is about to be clamped down. Without this, either
  /// would silently happen at Confirm & Finish with no indication which
  /// answer it hit.
  String? _marksWarning(_AnswerControllers row) {
    final raw = row.marks.text.trim();
    if (raw.isEmpty) return 'Will be saved as 0';
    final parsed = double.tryParse(raw);
    if (parsed == null) return 'Not a number — will be saved as 0';
    if (parsed < 0) return 'Will be saved as 0';
    if (parsed > row.maxMarks) return 'Max is ${row.maxMarks} — will be capped';
    return null;
  }

  Color _confidenceColor(MarkingConfidence c) => switch (c) {
        MarkingConfidence.high => Colors.green,
        MarkingConfidence.medium => Colors.orange,
        MarkingConfidence.low => Colors.red,
      };

  Widget _buildAnswerCard(BuildContext context, int index) {
    final row = _rows[index];
    final expected = widget.scheme?.questions
        .where((q) => q.label == row.questionLabel)
        .map((q) => q.expectedAnswerOrKeywords)
        .firstOrNull;
    final color = _confidenceColor(row.confidence);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color.withValues(alpha: 0.5), width: row.confidence == MarkingConfidence.low ? 2 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(row.questionLabel, style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                Chip(
                  label: Text(row.confidence.label, style: const TextStyle(fontSize: 11)),
                  backgroundColor: color.withValues(alpha: 0.15),
                  side: BorderSide(color: color.withValues(alpha: 0.4)),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            if (expected != null) ...[
              const SizedBox(height: 4),
              Text('Expected: $expected', style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: row.answer,
              decoration: const InputDecoration(labelText: 'Transcribed answer', border: OutlineInputBorder()),
              maxLines: 3,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: row.marks,
                    decoration: InputDecoration(
                      labelText: 'Marks (of ${row.maxMarks})',
                      border: const OutlineInputBorder(),
                      errorText: _marksWarning(row),
                      errorMaxLines: 2,
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
                    onChanged: (_) => setState(() {}),
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
