import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/marking_scheme.dart';
import '../services/marking_key_generation_service.dart';
import '../services/marking_scheme_section_marks.dart';

/// AI-Assisted Marking — the "get the total marks right" confirmation
/// step, shown right before a [MarkingScheme] is actually saved (from
/// both the AI-derivation flow and manual entry — MarkingSchemeBuilderScreen
/// routes here on every save, not just the AI path).
///
/// **Redesigned 2026-09-05, per explicit request**: a real exam's own
/// rules state each SECTION's total directly (e.g. "Section A = 30
/// marks, Section B = 30 marks, Section C: one essay = 20 marks, Section
/// D = 20 marks" — a real Zambian History paper's actual structure, per
/// the request that prompted this). The previous version asked for
/// "marks per question in this section" and multiplied by however many
/// rows were listed — which silently broke the moment a section's
/// questions were split into Roman-numeral sub-parts ("2(i)", "2(ii)",
/// "2(iii)"), since those are a CONTINUATION of one numbered question,
/// not three separate ones, and multiplying by the raw row count
/// overcounted. Now a teacher enters each section's own real total
/// directly — exactly the number they already know from the paper's own
/// rules — and marks are apportioned across that section's rows
/// automatically (see [apportionSectionMarks]): every row shares the
/// total when all of them get answered (Section A/B), or every row gets
/// the FULL total on its own when only one of several alternatives is
/// ever actually answered (Section C/D "answer ONE of the following"
/// essay style) — the app suggests which pattern fits from the section's
/// own printed answer instructions, but never applies it without the
/// teacher seeing and confirming it (see [SectionMarkingStyle]).
///
/// [derivedSections] carries the AI's own detected section headings and
/// their real printed answer-instructions (see
/// deriveMarkingKeyFromQuestionPaper's Cloud Function comment) when this
/// scheme came from an AI-derived marking key — used both as a hint shown
/// next to the matching section, and to suggest that section's marking
/// style. Empty for manual entry or a scheme with no detected sections.
class MarkingSchemePaperStructureScreen extends StatefulWidget {
  const MarkingSchemePaperStructureScreen({
    super.key,
    required this.draft,
    this.derivedSections = const [],
    this.aiMarkConventions = const [],
    this.aiExamStandardHint,
    this.aiDetectedTotalMarks,
  });

  final MarkingScheme draft;
  final List<DerivedMarkingKeySection> derivedSections;

  /// Rules Engine (2026-09-08) — the AI's own detected front-page marking
  /// conventions, exam-standard suggestion, and grand total, when this
  /// scheme came from an AI-derived marking key. Empty/null for manual
  /// entry or a re-edit of an already-saved scheme (which uses its own
  /// already-confirmed [MarkingScheme.markConventions]/[.examStandard]
  /// instead — see initState).
  final List<String> aiMarkConventions;
  final MarkingExamStandard? aiExamStandardHint;
  final double? aiDetectedTotalMarks;

  @override
  State<MarkingSchemePaperStructureScreen> createState() => _MarkingSchemePaperStructureScreenState();
}

/// Null key = questions with no section at all, grouped together under
/// "(No Section)" — a paper with no section structure ends up with just
/// this one group, so the screen degrades gracefully to "what's this
/// paper's total?" for a scheme with no sections whatsoever.
const String _noSectionKey = '';

/// Keywords a real standardized mock/national/final exam's own "type of
/// exam" or title tends to use — see [_looksLikeStandardizedExam]'s own
/// doc comment on how this is used (a suggestion only, never a hard
/// gate).
final _standardizedExamPattern = RegExp(
  r'\bmock\b|\bnational\b|\bfinal\b|\bexam(ination)?\b|\bprelim(inary)?\b|\btrial\b|\bpaper\s*(one|two|1|2)\b',
  caseSensitive: false,
);

/// True when [text] (the "type of exam" a teacher typed, or the AI's own
/// detected document title) reads like a standardized mock/national exam
/// rather than an ordinary class test — see this screen's own doc
/// comment on why that distinction matters (a real exam's section
/// structure follows well-known fixed rules; a class test's rules vary
/// assessment to assessment). A suggestion for which framing to show,
/// never a hard gate — the section-total confirmation below works
/// identically either way; only the extra "how do you want marks
/// allocated" guidance prompt is gated on this.
bool _looksLikeStandardizedExam(String text) => _standardizedExamPattern.hasMatch(text);

class _MarkingSchemePaperStructureScreenState extends State<MarkingSchemePaperStructureScreen> {
  final Map<String, TextEditingController> _sectionTotalControllers = {};
  final Map<String, SectionMarkingStyle> _sectionStyles = {};
  late final List<String> _sectionKeys;
  late final Map<String, List<MarkingSchemeQuestion>> _questionsBySection;
  late final bool _looksStandardized;
  TextEditingController? _gradingGuidanceController;

  /// Rules Engine (2026-09-08) — one convention per line, pre-filled from
  /// the AI's own front-page extraction (or, when re-editing an
  /// already-saved scheme, from its own already-confirmed conventions),
  /// always teacher-editable.
  late final TextEditingController _markConventionsController;
  late MarkingExamStandard _examStandard;

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
      final questions = _questionsBySection[key]!;
      final instructions = _instructionsFor(key) ?? '';
      _sectionStyles[key] = suggestSectionMarkingStyle(instructions);
      // Pre-filled with whatever the currently-listed rows already sum
      // to, as a starting point — the teacher's job here is to correct
      // this to the paper's own REAL stated total, not necessarily to
      // accept this guess. Left blank when everything's currently zero
      // (nothing to guess from yet), same as the previous version did
      // for an inconsistent/empty section.
      final currentSum = questions.fold<double>(0, (sum, q) => sum + q.maxMarks);
      _sectionTotalControllers[key] = TextEditingController(
        text: currentSum > 0 ? _formatMarks(currentSum) : '',
      );
    }

    // Best-effort signal only (see _looksLikeStandardizedExam's own doc
    // comment) — topicName carries the teacher-typed "type of exam" for
    // schemes from the marking-key-upload flow (see
    // MarkingSchemeBuilderScreen's own doc comment on why), and falls
    // back to the scheme's title for manually-built schemes.
    _looksStandardized =
        _looksLikeStandardizedExam(widget.draft.topicName) || _looksLikeStandardizedExam(widget.draft.title);
    if (!_looksStandardized) {
      _gradingGuidanceController = TextEditingController(text: widget.draft.gradingGuidance ?? '');
    }

    // Rules Engine (2026-09-08) — prefer the draft's OWN already-confirmed
    // values (a re-edit of an already-saved scheme, see
    // MarkingSchemeBuilderScreen's own doc comment) over the AI's fresh
    // draft suggestion, which only applies the first time a scheme is
    // saved from the AI-derivation flow.
    final startingConventions =
        widget.draft.markConventions.isNotEmpty ? widget.draft.markConventions : widget.aiMarkConventions;
    _markConventionsController = TextEditingController(text: startingConventions.join('\n'));

    _examStandard = widget.draft.examStandard != MarkingExamStandard.unspecified
        ? widget.draft.examStandard
        : (widget.aiExamStandardHint ??
            // No AI hint either (manual entry, or the AI genuinely found no
            // signal) — fall back to the same standardized-exam heuristic
            // this screen already computes for the grading-guidance prompt
            // above, since "looks like a mock/national exam" and "should be
            // marked to National Mock standard" are the same real signal.
            (_looksStandardized ? MarkingExamStandard.nationalMock : MarkingExamStandard.unspecified));
  }

  @override
  void dispose() {
    for (final c in _sectionTotalControllers.values) {
      c.dispose();
    }
    _gradingGuidanceController?.dispose();
    _markConventionsController.dispose();
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

  double? _confirmedTotalFor(String sectionKey) => double.tryParse(_sectionTotalControllers[sectionKey]!.text.trim());

  int _topLevelQuestionCountFor(String sectionKey) =>
      countTopLevelQuestions([for (final q in _questionsBySection[sectionKey]!) q.label]);

  /// Null while any section's total is empty/invalid — the live total
  /// simply doesn't show until every section is filled in, rather than
  /// silently treating a blank field as zero.
  double? get _computedTotal {
    var total = 0.0;
    for (final key in _sectionKeys) {
      final marks = _confirmedTotalFor(key);
      if (marks == null) return null;
      total += marks;
    }
    return total;
  }

  /// How many questions a candidate actually answers across the whole
  /// paper, GIVEN each section's confirmed marking style — one per
  /// section using [SectionMarkingStyle.oneRowGetsFullTotal] (only one
  /// alternative is ever chosen), every distinct top-level question for
  /// [SectionMarkingStyle.allRowsSumToTotal] (every one of them is
  /// answered). Computed, not asked — the previous version made a
  /// teacher type this separately, which could silently disagree with
  /// what the section structure below already implies.
  int get _derivedRequiredAnswerCount {
    var count = 0;
    for (final key in _sectionKeys) {
      count += _sectionStyles[key] == SectionMarkingStyle.oneRowGetsFullTotal ? 1 : _topLevelQuestionCountFor(key);
    }
    return count;
  }

  void _confirmAndReturn() {
    final total = _computedTotal;
    final updatedQuestions = <MarkingSchemeQuestion>[];
    for (final key in _sectionKeys) {
      final questions = _questionsBySection[key]!;
      final sectionTotal = _confirmedTotalFor(key)!;
      final style = _sectionStyles[key]!;
      final apportioned = apportionSectionMarks([for (final q in questions) q.maxMarks], sectionTotal, style);
      for (var i = 0; i < questions.length; i++) {
        updatedQuestions.add(questions[i].copyWith(maxMarks: apportioned[i]));
      }
    }
    final guidance = _gradingGuidanceController?.text.trim();
    final conventions = _markConventionsController.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    Navigator.of(context).pop<MarkingScheme>(
      widget.draft.copyWith(
        questions: updatedQuestions,
        requiredAnswerCount: _derivedRequiredAnswerCount,
        confirmedPaperTotalMarks: total,
        gradingGuidance: guidance == null || guidance.isEmpty ? null : guidance,
        examStandard: _examStandard,
        markConventions: conventions,
      ),
    );
  }

  void _skip() => Navigator.of(context).pop<MarkingScheme>(widget.draft);

  bool get _canConfirm => _computedTotal != null;

  /// Human-readable reason the button is disabled, shown right above it —
  /// a real, reported bug (2026-09-04) was this button staying disabled
  /// with zero explanation of why; never repeat that regardless of how
  /// this screen's own fields change shape.
  String? get _blockingReason {
    final missingSections = [
      for (final key in _sectionKeys)
        if (_confirmedTotalFor(key) == null) (key == _noSectionKey ? '(No Section)' : key),
    ];
    if (missingSections.isNotEmpty) {
      return 'Enter the total marks for: ${missingSections.join(', ')}.';
    }
    return null;
  }

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
            _looksStandardized
                ? 'Enter each section\'s own real total marks, straight from the paper\'s own rules (e.g. '
                    '"Section A = 30 marks") — not a guess, and not multiplied from a per-question value.'
                : 'This looks like a class test rather than a standardized mock/national exam, so its own mark '
                    'allocation is yours to set — enter each section\'s total the way you want it marked.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (_gradingGuidanceController case final controller?) ...[
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'How should marks be allocated for this test? (optional notes for your own records)',
                border: OutlineInputBorder(),
                hintText: 'e.g. "Open book, half marks for a partially correct working"',
              ),
              maxLines: 3,
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: 24),
          Text('Marking standard', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'A National Mock is marked to the identical standard as the real ECZ national exam. A School '
            'CA Test (Mid-Term/End-of-Term) is marked just as accurately, but its own weighted contribution '
            'to a term mark is handled separately in Data Manager.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<MarkingExamStandard>(
            segments: const [
              ButtonSegment(
                value: MarkingExamStandard.nationalMock,
                label: Text('National Mock', style: TextStyle(fontSize: 11.5)),
              ),
              ButtonSegment(
                value: MarkingExamStandard.schoolCa,
                label: Text('School CA Test', style: TextStyle(fontSize: 11.5)),
              ),
              ButtonSegment(
                value: MarkingExamStandard.unspecified,
                label: Text('Not sure', style: TextStyle(fontSize: 11.5)),
              ),
            ],
            selected: {_examStandard},
            onSelectionChanged: (selected) => setState(() => _examStandard = selected.first),
          ),
          const SizedBox(height: 20),
          Text('Marking conventions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            widget.aiMarkConventions.isNotEmpty
                ? 'Detected from this paper\'s own front page — check these are right, and add/remove any '
                    'as needed (one per line).'
                : 'Anything this paper\'s own front page states about how marks are awarded, one per line '
                    '(e.g. "one mark per bullet point", "accept alternative answers separated by /"). '
                    'Leave blank to use sensible defaults.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _markConventionsController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'One convention per line',
              isDense: true,
            ),
            maxLines: 4,
            onChanged: (_) => setState(() {}),
          ),
          if (widget.aiDetectedTotalMarks case final detected? when (detected - (_computedTotal ?? detected)).abs() >= 0.5) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'The paper\'s own front page states a total of ${_formatMarks(detected)} marks, but the '
                'section totals below currently add up to ${_formatMarks(_computedTotal ?? 0)}. Worth '
                'double-checking before saving.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text('Section totals', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            _sectionKeys.length == 1 && _sectionKeys.single == _noSectionKey
                ? 'This paper has no section headings — confirm its total marks below.'
                : 'Confirm each section\'s own real total marks.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final key in _sectionKeys) _buildSectionCard(key),
          const SizedBox(height: 20),
          if (total != null) ...[
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
            const SizedBox(height: 8),
            Text(
              'A candidate answers $_derivedRequiredAnswerCount question(s) in total across '
              '${_sectionKeys.length} section(s), based on the structure above.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_canConfirm)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _blockingReason ?? '',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                ),
              FilledButton.icon(
                onPressed: _canConfirm ? _confirmAndReturn : null,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Confirm & Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionCard(String key) {
    final questions = _questionsBySection[key]!;
    final title = key == _noSectionKey ? '(No Section)' : key;
    final instructions = _instructionsFor(key);
    final topLevelCount = _topLevelQuestionCountFor(key);
    final style = _sectionStyles[key]!;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            Text(
              topLevelCount == questions.length
                  ? '$topLevelCount question(s)'
                  : '$topLevelCount question(s) (${questions.length} row(s) listed, including sub-parts)',
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
              controller: _sectionTotalControllers[key],
              decoration: InputDecoration(
                labelText: key == _noSectionKey ? 'Total marks for this paper' : 'Total marks for $title',
                border: const OutlineInputBorder(),
                errorText: _confirmedTotalFor(key) == null ? 'Required' : null,
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Text('How is this section marked?', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            SegmentedButton<SectionMarkingStyle>(
              segments: const [
                ButtonSegment(
                  value: SectionMarkingStyle.allRowsSumToTotal,
                  label: Text('Every question shares this total', style: TextStyle(fontSize: 11.5)),
                ),
                ButtonSegment(
                  value: SectionMarkingStyle.oneRowGetsFullTotal,
                  label: Text('Only ONE is answered, in full', style: TextStyle(fontSize: 11.5)),
                ),
              ],
              selected: {style},
              onSelectionChanged: (selected) => setState(() => _sectionStyles[key] = selected.first),
            ),
          ],
        ),
      ),
    );
  }
}
