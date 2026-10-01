import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/marking_rubric.dart';

/// What the teacher decided on the structure-confirmation screen.
/// [rubric] is null for an explicit "no sections — mark as a plain total"
/// confirmation, which is a real, valid outcome, not a cancellation.
class CohortStructureConfirmation {
  final MarkingRubric? rubric;
  const CohortStructureConfirmation(this.rubric);
}

/// Marking Reliability Stage 1 (2026-09-22, per explicit request, following
/// a real incident where an AI-derived exam structure was silently wrong and
/// produced an out-of-range "900 / 100" result — see
/// ConciseScoreCalculator's own Stage 2 safeguard). Shown BEFORE any script
/// in a Concise Marking cohort is marked: the exam structure read off the
/// first script's cover page (total sections, each section's rule in plain
/// language, the stated grand total) is displayed for the teacher to
/// confirm or correct. Marking only begins once they explicitly do so — the
/// same "review before apply" pattern already used by
/// [MarkingSchemePaperStructureScreen] for the marking-scheme builder,
/// reused here for the same reason: never let an AI-derived structure the
/// teacher never saw be the one actually used to score a script.
class MarkingCohortStructureScreen extends StatefulWidget {
  const MarkingCohortStructureScreen({super.key, required this.initialRubric, this.subjectName});

  /// What the AI read off the cover page — null if it found no structure at
  /// all, or if reading it failed and the teacher is being asked to confirm
  /// "no structure" from scratch rather than block marking entirely.
  final MarkingRubric? initialRubric;
  final String? subjectName;

  @override
  State<MarkingCohortStructureScreen> createState() => _MarkingCohortStructureScreenState();
}

class _SectionDraft {
  final _key = UniqueKey();
  final TextEditingController name;
  final TextEditingController questionsToAnswer; // empty = "answer ALL"
  final TextEditingController marksAllocated; // empty = "not stated"

  _SectionDraft({String name = '', int? questionsToAnswer, double? marksAllocated})
      : name = TextEditingController(text: name),
        questionsToAnswer = TextEditingController(text: questionsToAnswer?.toString() ?? ''),
        marksAllocated = TextEditingController(text: marksAllocated == null ? '' : _fmt(marksAllocated));

  static String _fmt(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toString();

  void dispose() {
    name.dispose();
    questionsToAnswer.dispose();
    marksAllocated.dispose();
  }
}

class _MarkingCohortStructureScreenState extends State<MarkingCohortStructureScreen> {
  final List<_SectionDraft> _sections = [];
  late final TextEditingController _paperTotalController;
  late final TextEditingController _summaryController;

  @override
  void initState() {
    super.initState();
    final r = widget.initialRubric;
    for (final s in r?.sections ?? const []) {
      _sections.add(_SectionDraft(name: s.name, questionsToAnswer: s.questionsToAnswer, marksAllocated: s.marksAllocated));
    }
    _paperTotalController = TextEditingController(text: r?.paperTotalMarks == null ? '' : _SectionDraft._fmt(r!.paperTotalMarks!));
    _summaryController = TextEditingController(text: r?.instructionsSummary ?? '');
  }

  @override
  void dispose() {
    for (final s in _sections) {
      s.dispose();
    }
    _paperTotalController.dispose();
    _summaryController.dispose();
    super.dispose();
  }

  void _addSection() => setState(() => _sections.add(_SectionDraft()));
  void _removeSection(_SectionDraft s) => setState(() {
        _sections.remove(s);
        s.dispose();
      });

  double? _sumAllocated() {
    if (_sections.isEmpty) return null;
    var sum = 0.0;
    var any = false;
    for (final s in _sections) {
      final v = double.tryParse(s.marksAllocated.text.trim());
      if (v != null) {
        sum += v;
        any = true;
      }
    }
    return any ? sum : null;
  }

  void _confirm() {
    // Blank rows the teacher never filled in are dropped rather than saved
    // as an empty, meaningless section.
    final sections = <RubricSection>[
      for (final s in _sections)
        if (s.name.text.trim().isNotEmpty)
          RubricSection(
            name: s.name.text.trim(),
            questionsToAnswer: int.tryParse(s.questionsToAnswer.text.trim()),
            marksAllocated: double.tryParse(s.marksAllocated.text.trim()),
          ),
    ];
    final paperTotal = double.tryParse(_paperTotalController.text.trim());
    final summary = _summaryController.text.trim();

    final rubric = (sections.isEmpty && paperTotal == null && summary.isEmpty)
        ? null // explicit "no structure — plain sum" confirmation
        : MarkingRubric(sections: sections, paperTotalMarks: paperTotal, instructionsSummary: summary);

    Navigator.of(context).pop(CohortStructureConfirmation(rubric));
  }

  @override
  Widget build(BuildContext context) {
    final sumAllocated = _sumAllocated();
    final paperTotal = double.tryParse(_paperTotalController.text.trim());
    final mismatch = sumAllocated != null && paperTotal != null && (sumAllocated - paperTotal).abs() >= 0.5;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Exam Structure'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(const CohortStructureConfirmation(null)),
            child: const Text('No sections'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Text(
            widget.initialRubric == null
                ? "The AI didn't find a clear section structure on the cover page — check this is right, or "
                    'add sections below if it missed them. This applies to every script in this cohort.'
                : "Read from this script's cover page — check it's right before marking begins. This structure "
                    'will be applied to every script in this cohort, not just this one.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (widget.initialRubric?.instructionsSummary.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
              child: Text('AI read: "${widget.initialRubric!.instructionsSummary}"',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
            ),
          ],
          const SizedBox(height: 20),
          Text('Sections', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'For each section: how many questions must be answered (leave blank for "answer ALL"), and '
            'the marks it carries (leave blank if the paper states none).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final s in _sections) _buildSectionCard(s),
          OutlinedButton.icon(
            onPressed: _addSection,
            icon: const Icon(Icons.add_outlined),
            label: Text(_sections.isEmpty ? 'Add a section' : 'Add another section'),
          ),
          const SizedBox(height: 20),
          Text('Paper total', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _paperTotalController,
            decoration: const InputDecoration(
              labelText: 'Total marks for this paper (leave blank if not stated)',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
            onChanged: (_) => setState(() {}),
          ),
          if (mismatch) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer, borderRadius: BorderRadius.circular(8)),
              child: Text(
                'The sections above add up to ${_SectionDraft._fmt(sumAllocated)}, but the paper total is set to '
                '${_SectionDraft._fmt(paperTotal)} — worth double-checking before you continue. This exact kind of '
                'mismatch is what previously caused a script to be scored wrongly.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          const SizedBox(height: 20),
          Text('Notes (optional)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _summaryController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Any other marking rules from the cover page worth remembering',
              isDense: true,
            ),
            maxLines: 3,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            onPressed: _confirm,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Confirm & Start Marking'),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionCard(_SectionDraft s) {
    return Card(
      key: s._key,
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
                    controller: s.name,
                    decoration: const InputDecoration(labelText: 'Section name', border: OutlineInputBorder(), isDense: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  onPressed: () => _removeSection(s),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove this section',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: s.questionsToAnswer,
                    decoration: const InputDecoration(
                      labelText: 'Answer how many? (blank = ALL)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: s.marksAllocated,
                    decoration: const InputDecoration(labelText: 'Marks for this section', border: OutlineInputBorder(), isDense: true),
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
