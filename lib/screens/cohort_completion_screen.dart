import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/marking_script_repository.dart';
import '../services/marksheet_document_service.dart';
import 'marking_review_screen.dart';

/// What the teacher chose at the very end of a completed cohort — read by
/// [MarkingQueueScreen] to decide what happens next: clear the remembered
/// subject/scheme so "Upload Script" asks fresh for a new class, or leave
/// AutoGrade entirely.
enum CohortCompletionAction { nextCohort, closeAutoGrade }

/// "Completed Marking Cohort" — the end-of-class checkpoint for one marking
/// scheme's worth of scripts. Two phases in one screen (not two screens),
/// since the transition between them is itself the point: (1) any script
/// with an error, still unreviewed, or incomplete is highlighted red and
/// opened for a fix on tap; the moment none remain, "Marking Session of
/// Cohort Completed" is shown; (2) then a score graph + the full
/// alphabetical name/score list, sharable as a Word document, with
/// "Next Cohort" / "Close AutoGrade" as the final choice.
class CohortCompletionScreen extends StatefulWidget {
  const CohortCompletionScreen({
    super.key,
    required this.scheme,
    this.repository,
    this.documentService,
  });

  final MarkingScheme scheme;
  final MarkingScriptRepository? repository;
  final MarksheetDocumentService? documentService;

  @override
  State<CohortCompletionScreen> createState() => _CohortCompletionScreenState();
}

class _CohortCompletionScreenState extends State<CohortCompletionScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarksheetDocumentService _documentService = widget.documentService ?? MarksheetDocumentService();

  bool _loading = true;
  List<MarkingScript> _cohortScripts = const [];
  bool _showingSummary = false;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await _repository.loadCatalog();
    if (!mounted) return;
    setState(() {
      _cohortScripts = catalog.scripts.where((s) => s.schemeId == widget.scheme.id).toList();
      _loading = false;
    });
    _checkForCompletion();
  }

  /// A script that has entered the pipeline (queued or later) but hasn't
  /// reached a real grade yet — the cohort can't be completed while any of
  /// these remain, since there's nothing to review or graph for them yet.
  List<MarkingScript> get _pendingScripts => _cohortScripts
      .where((s) => s.status == MarkingScriptStatus.queued || s.status == MarkingScriptStatus.processing)
      .toList();

  /// Error (needs retry), unreviewed (AI-graded but a teacher hasn't
  /// confirmed it), or incomplete (reviewed but with fewer recorded
  /// answers than the scheme has questions — can genuinely happen if a
  /// question was edited away during review) — every real reason a
  /// script isn't safely "final" yet.
  bool _hasProblem(MarkingScript s) {
    if (s.status == MarkingScriptStatus.needsRetry) return true;
    if (s.status == MarkingScriptStatus.graded) return true;
    if (s.status == MarkingScriptStatus.reviewed) {
      final answers = s.gradedAnswers;
      if (answers == null || answers.length < widget.scheme.questions.length) return true;
    }
    return false;
  }

  List<MarkingScript> get _problemScripts => _cohortScripts.where(_hasProblem).toList();

  /// Sorted by surname — the standard class-register convention this app
  /// already uses for "Marked Students" (see MarkingQueueScreen) and for
  /// the Word marksheet itself.
  List<MarkingScript> get _alphabeticalCleanScripts {
    final clean = _cohortScripts.where((s) => !_hasProblem(s)).toList()
      ..sort((a, b) => a.surname.toLowerCase().compareTo(b.surname.toLowerCase()));
    return clean;
  }

  double _percentFor(MarkingScript script) {
    final total = widget.scheme.totalMarks;
    if (total <= 0) return 0;
    return ((script.totalAwarded ?? 0) / total) * 100;
  }

  /// Fires once, the moment the cohort first has zero pending and zero
  /// problem scripts — whether that's true immediately (nothing needed
  /// fixing) or only after the teacher worked through every flagged
  /// script one by one.
  void _checkForCompletion() {
    if (_showingSummary || _loading) return;
    if (_cohortScripts.isEmpty) return;
    if (_pendingScripts.isNotEmpty || _problemScripts.isNotEmpty) return;

    setState(() => _showingSummary = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: const Text('Marking Session of Cohort Completed'),
          actions: [
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK')),
          ],
        ),
      );
    });
  }

  Future<void> _openForFix(MarkingScript script) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MarkingReviewScreen(script: script, scheme: widget.scheme, repository: _repository),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  /// For the real case a red-flagged script doesn't get fixed in place —
  /// the original capture had a real glitch (a torn page, an unreadable
  /// photo, wrong pages attached) and the teacher instead re-captured the
  /// whole script fresh as a new entry for the same learner. Once that
  /// clean replacement exists, the old flagged one is dead weight, not
  /// something to review — this deletes it outright, same underlying
  /// action as the main queue's own "Delete" (MarkingScriptRepository
  /// .remove), just reachable from where a flagged entry is actually
  /// looked at, and worded for this specific situation so it isn't
  /// confused with deleting a script that still needs fixing.
  Future<void> _deleteFlaggedScript(MarkingScript script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this flagged entry?'),
        content: Text(
          'Use this only if the problem with ${script.fullName}\'s script (Script ${script.scriptNumber}) has '
          'already been corrected by capturing a fresh, clearer entry for the same learner elsewhere in the '
          'queue — this deletes only this flagged copy, permanently, including its captured pages. If you '
          'haven\'t re-captured a replacement yet, cancel and fix this entry instead.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _repository.remove(script);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted the flagged entry for ${script.fullName}.')),
    );
    await _load();
  }

  Future<void> _shareList() async {
    setState(() => _sharing = true);
    try {
      final file = await _documentService.generateDocx(widget.scheme, _alphabeticalCleanScripts);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: '${widget.scheme.title} — Results'),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not build the results list: $error')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Cohort — ${widget.scheme.title}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _showingSummary
              ? _buildSummary(context)
              : _buildIssueReview(context),
    );
  }

  Widget _buildIssueReview(BuildContext context) {
    final pending = _pendingScripts;
    final problems = _problemScripts;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (pending.isNotEmpty)
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${pending.length} script(s) for this class are still queued or being marked.',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text('Process them from the AutoGrade queue before completing this cohort.'),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back to Queue'),
                  ),
                ],
              ),
            ),
          ),
        if (pending.isEmpty && problems.isNotEmpty) ...[
          Text(
            '${problems.length} student(s) need attention before this cohort can be completed',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          const Text(
            'Highlighted in red — an error, an AI-graded script not yet reviewed, or an incomplete set of '
            'answers. Tap one to open and fix it — or, if you\'ve already re-captured a clearer entry for the '
            'same learner elsewhere, use the delete icon to remove this flagged copy instead.',
          ),
          const SizedBox(height: 12),
          for (final script in problems) _buildProblemTile(context, script),
        ],
        if (pending.isEmpty && problems.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Widget _buildProblemTile(BuildContext context, MarkingScript script) {
    final reason = script.status == MarkingScriptStatus.needsRetry
        ? 'Error — ${script.lastError ?? 'grading failed'}'
        : script.status == MarkingScriptStatus.graded
            ? 'Not yet reviewed'
            : 'Incomplete answers';
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
        title: Text(script.fullName, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(reason),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete — already corrected with a fresh entry',
              onPressed: () => _deleteFlaggedScript(script),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => _openForFix(script),
      ),
    );
  }

  Widget _buildSummary(BuildContext context) {
    final scripts = _alphabeticalCleanScripts;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            children: [
              Text('Cohort Scores', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              _ScoreBarChart(scripts: scripts, percentFor: _percentFor),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: Text('Results (${scripts.length})', style: Theme.of(context).textTheme.titleMedium)),
                  OutlinedButton.icon(
                    onPressed: _sharing ? null : _shareList,
                    icon: _sharing
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.share_outlined),
                    label: const Text('Share (Word)'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final script in scripts)
                Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    title: Text(script.fullName),
                    trailing: Text(
                      '${_percentFor(script).toStringAsFixed(0)}%',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(CohortCompletionAction.closeAutoGrade),
                  child: const Text('Close AutoGrade'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(CohortCompletionAction.nextCohort),
                  child: const Text('Next Cohort'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A minimal, hand-drawn bar chart — one bar per student, height scaled to
/// their percentage, horizontally scrollable for a large class. No chart
/// package added, matching how this app already draws its PDF results
/// graph (AnalysisDocumentService.generateGraphPdf) with plain Containers.
class _ScoreBarChart extends StatelessWidget {
  const _ScoreBarChart({required this.scripts, required this.percentFor});

  final List<MarkingScript> scripts;
  final double Function(MarkingScript) percentFor;

  static const _chartHeight = 160.0;

  @override
  Widget build(BuildContext context) {
    if (scripts.isEmpty) {
      return const SizedBox(height: _chartHeight, child: Center(child: Text('No scores to show yet.')));
    }
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: _chartHeight + 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final script in scripts)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(percentFor(script).toStringAsFixed(0), style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 2),
                    Container(
                      width: 22,
                      height: (_chartHeight * (percentFor(script).clamp(0, 100) / 100)).clamp(2.0, _chartHeight),
                      decoration: BoxDecoration(
                        color: primary,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 40,
                      child: Text(
                        script.surname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
