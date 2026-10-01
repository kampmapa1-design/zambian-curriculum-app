import 'package:flutter/material.dart';

import '../models/marking_scheme_node.dart';
import '../services/marking_scheme_checksum.dart';

String _fmtMarks(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);

/// Marking Scheme Structure Stages 3-5 (2026-09-22) — shown once per newly
/// AI-derived marking key, before it's ever saved or used to grade a
/// script. One card per section: what the AI found (question count,
/// required-answer count, marks, an indented tree preview), a prominent
/// "Confirm" and a smaller "Edit" button. Only once every section is
/// confirmed does "Continue" run the Stage 5 checksum — a real mismatch
/// blocks proceeding rather than silently carrying a wrong total into
/// grading (the same class of bug the History "900/100" incident was).
class MarkingSchemeStructureConfirmationScreen extends StatefulWidget {
  const MarkingSchemeStructureConfirmationScreen({
    super.key,
    required this.sectionTree,
    this.detectedTotalMarks,
  });

  final List<MarkingSchemeSection> sectionTree;
  final double? detectedTotalMarks;

  @override
  State<MarkingSchemeStructureConfirmationScreen> createState() => _MarkingSchemeStructureConfirmationScreenState();
}

class _MarkingSchemeStructureConfirmationScreenState extends State<MarkingSchemeStructureConfirmationScreen> {
  late List<MarkingSchemeSection> _sections = widget.sectionTree;
  final Set<int> _confirmed = {};

  bool get _allConfirmed => _confirmed.length == _sections.length;

  Future<void> _editSection(int index) async {
    final edited = await Navigator.of(context).push<MarkingSchemeSection>(
      MaterialPageRoute(builder: (_) => _SectionEditScreen(section: _sections[index])),
    );
    if (edited == null || !mounted) return;
    setState(() {
      _sections = [..._sections]..[index] = edited;
      _confirmed.add(index);
    });
  }

  void _confirmSection(int index) => setState(() => _confirmed.add(index));

  void _continue() {
    final checksum = checkMarkingSchemeChecksum(sections: _sections, statedGrandTotal: widget.detectedTotalMarks);
    if (!checksum.matches) {
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('The marks don\'t add up'),
          content: Text(
            'This paper states a total of ${_fmtMarks(checksum.statedTotal!)} marks, but the confirmed sections '
            'add up to ${_fmtMarks(checksum.sumOfSections)}.\n\n'
            'Check each section\'s total below and use Edit to correct whichever one looks wrong before '
            'continuing:\n\n'
            '${_sections.map((s) => '${s.name.isEmpty ? '(no section)' : s.name}: ${_fmtMarks(s.totalMarksIfAllAnswered)} marks').join('\n')}',
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Review again')),
          ],
        ),
      );
      return;
    }
    Navigator.of(context).pop(_sections);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm Marking Scheme Structure')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Check what the AI found for each section before this marking key is saved — you can edit any '
            'section that doesn\'t look right.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < _sections.length; i++) _sectionCard(i),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _allConfirmed ? _continue : null,
            child: Text(_allConfirmed ? 'Continue' : 'Confirm every section to continue'),
          ),
        ),
      ),
    );
  }

  Widget _sectionCard(int index) {
    final section = _sections[index];
    final confirmed = _confirmed.contains(index);
    final questionCount = section.questions.length;
    final requiredText = section.requiredAnswerCount == null ? 'all $questionCount' : '${section.requiredAnswerCount}';
    final marksText = _marksSummary(section);
    final displayName = section.name.trim().isEmpty ? '(No section heading)' : section.name;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: confirmed ? Theme.of(context).colorScheme.surfaceContainerHighest : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$displayName — $questionCount question${questionCount == 1 ? '' : 's'}, answer $requiredText, '
                    'each worth $marksText',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (confirmed) Icon(Icons.check_circle_outlined, color: Colors.green.shade700, size: 20),
              ],
            ),
            const SizedBox(height: 8),
            _TreePreview(questions: section.questions),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => _confirmSection(index),
                    child: Text(confirmed ? 'Confirmed' : 'Yes, this is right'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => _editSection(index), child: const Text('Edit')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// A shared value when every top-level question in [section] is worth the
  /// same real total (the common real case — "each worth 20 marks");
  /// otherwise an honest range rather than a misleading single number.
  String _marksSummary(MarkingSchemeSection section) {
    if (section.questions.isEmpty) return '0';
    final totals = section.questions.map((q) => q.totalMarks).toSet();
    if (totals.length == 1) return _fmtMarks(totals.single);
    final min = totals.reduce((a, b) => a < b ? a : b);
    final max = totals.reduce((a, b) => a > b ? a : b);
    return '${_fmtMarks(min)}–${_fmtMarks(max)}';
  }
}

/// Stage 3's indented visual preview of a section's own real hierarchy —
/// read-only, purely so a teacher can see the AI's structure at a glance
/// before deciding Yes or Edit.
class _TreePreview extends StatelessWidget {
  const _TreePreview({required this.questions});

  final List<MarkingSchemeNode> questions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final q in questions) ..._rows(context, q, depth: 0, ancestorFullLabel: null)],
    );
  }

  List<Widget> _rows(BuildContext context, MarkingSchemeNode node, {required int depth, required String? ancestorFullLabel}) {
    final here = node.fullLabel(ancestorFullLabel);
    final row = Padding(
      padding: EdgeInsets.only(left: depth * 20.0, bottom: 2),
      child: Text(
        '$here — ${node.totalMarks == node.totalMarks.roundToDouble() ? node.totalMarks.toInt() : node.totalMarks} mark${node.totalMarks == 1 ? '' : 's'}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
    return [row, for (final c in node.children) ..._rows(context, c, depth: depth + 1, ancestorFullLabel: here)];
  }
}

/// Stage 4 — a minimal, pre-filled edit form: the section's own required-
/// answer count, plus every real LEAF's own mark value (the only place a
/// raw mark genuinely lives — see MarkingSchemeNode's own doc comment).
/// Doesn't support reshaping the tree itself (adding/removing a part) —
/// only correcting values the AI got wrong, which covers the common real
/// correction a teacher needs to make.
class _SectionEditScreen extends StatefulWidget {
  const _SectionEditScreen({required this.section});

  final MarkingSchemeSection section;

  @override
  State<_SectionEditScreen> createState() => _SectionEditScreenState();
}

class _SectionEditScreenState extends State<_SectionEditScreen> {
  late final TextEditingController _requiredController =
      TextEditingController(text: widget.section.requiredAnswerCount?.toString() ?? '');
  final Map<String, TextEditingController> _markControllers = {};
  late final List<(String fullLabel, MarkingSchemeNode leaf)> _leaves = [
    for (final q in widget.section.questions) ...q.leaves(),
  ];

  @override
  void initState() {
    super.initState();
    for (final (label, leaf) in _leaves) {
      _markControllers[label] = TextEditingController(text: _fmtMarks(leaf.marks ?? 0));
    }
  }

  @override
  void dispose() {
    _requiredController.dispose();
    for (final c in _markControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final byLabel = <String, double>{};
    for (final entry in _markControllers.entries) {
      final parsed = double.tryParse(entry.value.text.trim());
      if (parsed != null && parsed >= 0) byLabel[entry.key] = parsed;
    }
    final requiredText = _requiredController.text.trim();
    final required = requiredText.isEmpty ? null : int.tryParse(requiredText);

    final updated = widget.section.withUpdatedLeafMarks(byLabel).copyWith(requiredAnswerCount: required);
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Edit ${widget.section.name.isEmpty ? "Section" : widget.section.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _requiredController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Questions the candidate must answer',
              helperText: 'Leave blank if every question listed must be answered',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text('Marks per question/part', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final (label, _) in _leaves)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: _markControllers[label],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(onPressed: _save, child: const Text('Save')),
        ),
      ),
    );
  }
}
