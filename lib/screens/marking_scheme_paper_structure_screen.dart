import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/marking_scheme.dart';
import '../services/marking_key_generation_service.dart';

/// AI-Assisted Marking — the "get the total marks right" confirmation
/// step, shown right before a [MarkingScheme] is actually saved (from
/// both the AI-derivation flow and manual entry — MarkingSchemeBuilderScreen
/// routes here on every save, not just the AI path).
///
/// The problem this solves: a flat sum of every listed question's marks
/// is wrong for a paper with a real "answer N of M" structure (e.g.
/// "Section B: answer any THREE of the following FIVE essay questions") —
/// summing all five would overstate the paper's real total. Rather than
/// guess how a teacher's "answer N of M" instruction should be resolved,
/// this screen asks the teacher directly, using their own knowledge of
/// the paper: how many questions a candidate must answer overall, and
/// what each section's questions are really worth — then computes the
/// paper's real total from those confirmed numbers and flags (without
/// blocking) any mismatch against how many questions are actually listed,
/// rather than silently trusting either number.
///
/// [derivedSections] carries the AI's own detected section headings and
/// their real printed answer-instructions (see
/// deriveMarkingKeyFromQuestionPaper's Cloud Function comment) when this
/// scheme came from an AI-derived marking key — shown as a hint next to
/// the matching section's own question here, never auto-applied. Empty
/// for manual entry or a scheme with no detected sections.
class MarkingSchemePaperStructureScreen extends StatefulWidget {
  const MarkingSchemePaperStructureScreen({
    super.key,
    required this.draft,
    this.derivedSections = const [],
  });

  final MarkingScheme draft;
  final List<DerivedMarkingKeySection> derivedSections;

  @override
  State<MarkingSchemePaperStructureScreen> createState() => _MarkingSchemePaperStructureScreenState();
}

/// Null key = questions with no section at all, grouped together under
/// "(No Section)" — a paper with no section structure ends up with just
/// this one group, so the screen degrades gracefully to "how many marks
/// does each question carry?" for a scheme with no sections whatsoever.
const String _noSectionKey = '';

class _MarkingSchemePaperStructureScreenState extends State<MarkingSchemePaperStructureScreen> {
  late final TextEditingController _requiredAnswerCountController;
  final Map<String, TextEditingController> _sectionMarksControllers = {};
  late final List<String> _sectionKeys;
  late final Map<String, List<MarkingSchemeQuestion>> _questionsBySection;

  @override
  void initState() {
    super.initState();
    _questionsBySection = {};
    for (final q in widget.draft.questions) {
      final key = q.sectionName?.trim().isNotEmpty == true ? q.sectionName!.trim() : _noSectionKey;
      _questionsBySection.putIfAbsent(key, () => []).add(q);
    }
    // Order: named sections in first-appearance order, "(No Section)" last
    // (it's the fallback bucket, not a real section the paper printed).
    _sectionKeys = [
      ...widget.draft.sectionNames,
      if (_questionsBySection.containsKey(_noSectionKey)) _noSectionKey,
    ];

    for (final key in _sectionKeys) {
      final marksInSection = _questionsBySection[key]!.map((q) => q.maxMarks).toList();
      final consistent = marksInSection.toSet().length == 1;
      _sectionMarksControllers[key] = TextEditingController(
        text: consistent ? _formatMarks(marksInSection.first) : '',
      );
    }

    _requiredAnswerCountController = TextEditingController(text: widget.draft.questions.length.toString());
  }

  @override
  void dispose() {
    _requiredAnswerCountController.dispose();
    for (final c in _sectionMarksControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _formatMarks(double marks) => marks == marks.roundToDouble() ? marks.toInt().toString() : marks.toString();

  String? _instructionsFor(String sectionKey) {
    if (sectionKey == _noSectionKey) return null;
    for (final s in widget.derivedSections) {
      if (s.name.trim().toLowerCase() == sectionKey.toLowerCase() && s.answerInstructions.trim().isNotEmpty) {
        return s.answerInstructions.trim();
      }
    }
    return null;
  }

  double? _confirmedMarksFor(String sectionKey) => double.tryParse(_sectionMarksControllers[sectionKey]!.text.trim());

  int get _listedQuestionCount => widget.draft.questions.length;

  int? get _requiredAnswerCount => int.tryParse(_requiredAnswerCountController.text.trim());

  /// Null while any section's marks-per-question field is empty/invalid —
  /// the live total simply doesn't show until every section is filled in,
  /// rather than silently treating a blank field as zero.
  double? get _computedTotal {
    var total = 0.0;
    for (final key in _sectionKeys) {
      final marks = _confirmedMarksFor(key);
      if (marks == null) return null;
      total += marks * _questionsBySection[key]!.length;
    }
    return total;
  }

  bool get _hasMismatch {
    final required = _requiredAnswerCount;
    return required != null && required != _listedQuestionCount;
  }

  void _confirmAndReturn() {
    final total = _computedTotal;
    final required = _requiredAnswerCount;
    final updatedQuestions = [
      for (final q in widget.draft.questions)
        q.copyWith(maxMarks: _confirmedMarksFor(q.sectionName?.trim().isNotEmpty == true ? q.sectionName!.trim() : _noSectionKey)),
    ];
    Navigator.of(context).pop<MarkingScheme>(
      widget.draft.copyWith(
        questions: updatedQuestions,
        requiredAnswerCount: required,
        confirmedPaperTotalMarks: total,
      ),
    );
  }

  void _skip() => Navigator.of(context).pop<MarkingScheme>(widget.draft);

  bool get _canConfirm => _computedTotal != null && _requiredAnswerCount != null && _requiredAnswerCount! > 0;

  @override
  Widget build(BuildContext context) {
    final total = _computedTotal;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Paper Structure'),
        actions: [
          TextButton(onPressed: _skip, child: const Text('Skip')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Text(
            'A couple of quick questions so this paper\'s total marks are right — especially important if '
            'some questions are optional (e.g. "answer any 3 of 5").',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _requiredAnswerCountController,
            decoration: const InputDecoration(
              labelText: 'How many questions must a candidate answer in total on this paper?',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
          ),
          if (_hasMismatch) ...[
            const SizedBox(height: 8),
            _WarningBanner(
              text: 'This marking key currently lists $_listedQuestionCount question(s), but you said '
                  'candidates answer ${_requiredAnswerCount ?? 0} in total. Double-check the questions before '
                  'saving — a candidate who answers fewer than what\'s listed is still graded correctly '
                  'question-by-question, but the paper\'s stated total marks should match what you confirm '
                  'here.',
            ),
          ],
          const SizedBox(height: 24),
          Text('Marks per section', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            _sectionKeys.length == 1 && _sectionKeys.single == _noSectionKey
                ? 'This paper has no section headings — confirm the mark value below.'
                : 'Confirm how many marks each question is worth in every section this key found.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final key in _sectionKeys) _buildSectionCard(key),
          const SizedBox(height: 20),
          if (total != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total marks for this paper'),
                  Text(
                    _formatMarks(total),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _canConfirm ? _confirmAndReturn : null,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Confirm & Save'),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionCard(String key) {
    final questions = _questionsBySection[key]!;
    final title = key == _noSectionKey ? '(No Section)' : key;
    final instructions = _instructionsFor(key);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            Text(
              '${questions.length} question(s) currently listed',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (instructions != null) ...[
              const SizedBox(height: 4),
              Text(
                'Paper says: "$instructions"',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _sectionMarksControllers[key],
              decoration: InputDecoration(
                labelText: key == _noSectionKey ? 'Marks per question' : 'Marks per question in $title',
                border: const OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
