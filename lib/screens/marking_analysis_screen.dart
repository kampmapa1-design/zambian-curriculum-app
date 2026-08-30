import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/grading_scale.dart';
import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/analysis_document_service.dart';
import '../services/marking_script_repository.dart';
import '../widgets/timed_choice_dialog.dart';

/// Minimum scripts needed before Analysis will show anything at all
/// (2026-08-31) — a single script's grade-band breakdown isn't a
/// meaningful class picture. Below this, the screen shows how many more
/// are needed rather than a report.
const int kAnalysisMinimumScripts = 10;

/// AI-Assisted Marking, Stage F — "Analysis": gender-segmented grade-band
/// counts (British Distinction/Merit/Credit/Satisfactory/Fail, or
/// American A-F) across scripts for one marking scheme, plus a results
/// list sortable alphabetically or by rank.
///
/// Two modes, gated by [kAnalysisMinimumScripts] (2026-08-31):
/// - **Final**: once at least [kAnalysisMinimumScripts]
///   [MarkingScriptStatus.reviewed] scripts exist — the same rule the
///   marksheet export uses, since a reviewed script is a confirmed mark.
/// - **Preliminary**: once at least [kAnalysisMinimumScripts] scripts are
///   *scored* (reviewed OR still awaiting review) — an early read on
///   trends before every script has been individually checked, clearly
///   labeled as such and using AI marks that haven't all been confirmed
///   yet. Final mode is preferred whenever there are enough reviewed
///   scripts to use it on its own.
class MarkingAnalysisScreen extends StatefulWidget {
  const MarkingAnalysisScreen({super.key, required this.scheme, this.scriptRepository});

  final MarkingScheme scheme;
  final MarkingScriptRepository? scriptRepository;

  @override
  State<MarkingAnalysisScreen> createState() => _MarkingAnalysisScreenState();
}

enum _SortMode { rankedHighestFirst, alphabetical }

enum _ExportFormat { pdf, docx, graph }

class _MarkingAnalysisScreenState extends State<MarkingAnalysisScreen> {
  late final MarkingScriptRepository _repository = widget.scriptRepository ?? MarkingScriptRepository();
  final AnalysisDocumentService _documentService = AnalysisDocumentService();

  bool _loading = true;
  bool _cancelled = false;
  List<MarkingScript> _scripts = [];
  bool _isPreliminary = false;
  int _reviewedCount = 0;
  int _scoredSoFarCount = 0;
  GradingSystem? _system;
  _SortMode _sortMode = _SortMode.rankedHighestFirst;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = (await _repository.loadCatalog()).scripts;
    final forScheme = all.where((s) => s.schemeId == widget.scheme.id && s.gradedAnswers != null);
    final reviewed = forScheme.where((s) => s.status == MarkingScriptStatus.reviewed).toList();
    final scoredSoFar = forScheme
        .where((s) => s.status == MarkingScriptStatus.reviewed || s.status == MarkingScriptStatus.graded)
        .toList();

    // Prefer Final (reviewed-only) whenever there are enough reviewed
    // scripts on their own; otherwise fall back to Preliminary (reviewed
    // + still-awaiting-review) once that pool alone clears the minimum.
    final List<MarkingScript> scripts;
    final bool preliminary;
    if (reviewed.length >= kAnalysisMinimumScripts) {
      scripts = reviewed;
      preliminary = false;
    } else if (scoredSoFar.length >= kAnalysisMinimumScripts) {
      scripts = scoredSoFar;
      preliminary = true;
    } else {
      scripts = [];
      preliminary = false;
    }

    if (!mounted) return;
    setState(() {
      _scripts = scripts;
      _isPreliminary = preliminary;
      _reviewedCount = reviewed.length;
      _scoredSoFarCount = scoredSoFar.length;
      _loading = false;
    });

    if (scripts.isEmpty) return;

    final chosen = await showTimedChoiceDialog<GradingSystem>(
      context: context,
      title: 'Grading system',
      message: 'Which grading system should results be classified under?',
      options: const [
        TimedChoiceOption(value: GradingSystem.british, label: 'British', icon: Icons.school_outlined),
        TimedChoiceOption(value: GradingSystem.american, label: 'American', icon: Icons.flag_outlined),
      ],
      defaultValue: GradingSystem.british,
      showCancel: true,
    );
    if (!mounted) return;
    if (chosen == null) {
      setState(() => _cancelled = true);
      return;
    }
    setState(() => _system = chosen);
  }

  double _percentFor(MarkingScript s) {
    final awarded = s.totalAwarded ?? 0;
    final possible = s.totalPossible ?? 0;
    if (possible <= 0) return 0;
    return (awarded / possible) * 100;
  }

  /// gender -> band's fullLabel -> count. Keyed by fullLabel, not label —
  /// the numbered scale has two bands sharing the same plain label
  /// (Merit appears for both grade 3 and grade 4, etc.), so label alone
  /// isn't a unique key; fullLabel ("Merit (3)") always is.
  Map<CandidateGender, Map<String, int>> get _counts {
    final system = _system!;
    final counts = <CandidateGender, Map<String, int>>{
      for (final g in CandidateGender.values) g: {for (final b in gradeBandsFor(system)) b.fullLabel: 0},
    };
    for (final s in _scripts) {
      final band = classify(_percentFor(s), system);
      counts[s.gender]![band.fullLabel] = (counts[s.gender]![band.fullLabel] ?? 0) + 1;
    }
    return counts;
  }

  List<MarkingScript> get _sortedScripts {
    final sorted = [..._scripts];
    if (_sortMode == _SortMode.alphabetical) {
      sorted.sort((a, b) {
        final bySurname = a.surname.toLowerCase().compareTo(b.surname.toLowerCase());
        return bySurname != 0 ? bySurname : a.firstName.toLowerCase().compareTo(b.firstName.toLowerCase());
      });
    } else {
      sorted.sort((a, b) => _percentFor(b).compareTo(_percentFor(a)));
    }
    return sorted;
  }

  List<AnalysisResultRow> get _resultRows => [
        for (final s in _sortedScripts) AnalysisResultRow(script: s, percent: _percentFor(s), band: classify(_percentFor(s), _system!)),
      ];

  Future<void> _export({required _ExportFormat format}) async {
    setState(() => _exporting = true);
    try {
      final file = switch (format) {
        _ExportFormat.docx =>
          await _documentService.generateDocx(scheme: widget.scheme, rows: _resultRows, system: _system!, counts: _counts),
        _ExportFormat.pdf =>
          await _documentService.generatePdf(scheme: widget.scheme, rows: _resultRows, system: _system!, counts: _counts),
        _ExportFormat.graph =>
          await _documentService.generateGraphPdf(scheme: widget.scheme, rows: _resultRows, system: _system!, counts: _counts),
      };
      if (!mounted) return;
      final subjectPrefix = _isPreliminary ? 'Preliminary Performance Analysis' : 'Performance Analysis';
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: '$subjectPrefix — ${widget.scheme.title}'),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create the analysis document: $error')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _changeGradingSystem() async {
    final chosen = await showTimedChoiceDialog<GradingSystem>(
      context: context,
      title: 'Grading system',
      message: 'Which grading system should results be classified under?',
      options: const [
        TimedChoiceOption(value: GradingSystem.british, label: 'British', icon: Icons.school_outlined),
        TimedChoiceOption(value: GradingSystem.american, label: 'American', icon: Icons.flag_outlined),
      ],
      defaultValue: _system ?? GradingSystem.british,
      showCancel: true,
    );
    if (chosen != null && mounted) setState(() => _system = chosen);
  }

  @override
  Widget build(BuildContext context) {
    final canExport = !_loading && !_cancelled && _scripts.isNotEmpty && _system != null;
    return Scaffold(
      appBar: AppBar(
        title: Text('${_isPreliminary ? 'Preliminary Analysis' : 'Analysis'} — ${widget.scheme.title}'),
        actions: [
          if (canExport)
            _exporting
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : PopupMenuButton<_ExportFormat>(
                    icon: const Icon(Icons.share_outlined),
                    tooltip: 'Export & share',
                    onSelected: (format) => _export(format: format),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: _ExportFormat.pdf, child: Text('Export as PDF (table)')),
                      PopupMenuItem(value: _ExportFormat.docx, child: Text('Export as Word (table)')),
                      PopupMenuItem(value: _ExportFormat.graph, child: Text('Export as Graph (PDF)')),
                    ],
                  ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _cancelled
              ? _buildCancelledState(context)
              : _scripts.isEmpty
                  ? _buildEmptyState(context)
                  : _system == null
                      ? const Center(child: CircularProgressIndicator())
                      : _buildAnalysis(context),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final remaining = kAnalysisMinimumScripts - _scoredSoFarCount;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.query_stats_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              _scoredSoFarCount == 0
                  ? 'No scripts scored yet for this scheme. Analysis needs at least $kAnalysisMinimumScripts scored '
                      'scripts before it can show anything meaningful.'
                  : '$_scoredSoFarCount of $kAnalysisMinimumScripts scripts scored so far — $remaining more '
                      'needed before a preliminary analysis becomes available.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: (_scoredSoFarCount / kAnalysisMinimumScripts).clamp(0, 1).toDouble(),
              minHeight: 6,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCancelledState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Analysis cancelled.', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                setState(() => _cancelled = false);
                _load();
              },
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalysis(BuildContext context) {
    final counts = _counts;
    final bands = gradeBandsFor(_system!);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (_isPreliminary) _buildPreliminaryBanner(context),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('${_system!.label} grading', style: Theme.of(context).textTheme.titleMedium),
            TextButton.icon(
              onPressed: _changeGradingSystem,
              icon: const Icon(Icons.swap_horiz, size: 16),
              label: const Text('Change'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildCountsTable(context, counts, bands),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Results (${_scripts.length})', style: Theme.of(context).textTheme.titleMedium),
            SegmentedButton<_SortMode>(
              segments: const [
                ButtonSegment(
                  value: _SortMode.rankedHighestFirst,
                  label: Text('Ranked'),
                  icon: Icon(Icons.leaderboard_outlined, size: 16),
                ),
                ButtonSegment(
                  value: _SortMode.alphabetical,
                  label: Text('A–Z'),
                  icon: Icon(Icons.sort_by_alpha, size: 16),
                ),
              ],
              selected: {_sortMode},
              onSelectionChanged: (s) => setState(() => _sortMode = s.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildResultsList(context, bands),
      ],
    );
  }

  /// Shown only in preliminary mode ([_isPreliminary]) — makes it obvious
  /// this isn't the final picture: it includes scripts still awaiting
  /// teacher review, so counts may shift once every script is confirmed.
  Widget _buildPreliminaryBanner(BuildContext context) {
    final awaitingReview = _scoredSoFarCount - _reviewedCount;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.hourglass_top_outlined, size: 18, color: Theme.of(context).colorScheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'PRELIMINARY — based on $_scoredSoFarCount scored scripts ($_reviewedCount reviewed, '
              '$awaitingReview still awaiting review). This will update as more scripts are reviewed.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onTertiaryContainer, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountsTable(BuildContext context, Map<CandidateGender, Map<String, int>> counts, List<GradeBand> bands) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 20,
            columns: [
              const DataColumn(label: Text('')),
              for (final band in bands) DataColumn(label: Text(band.fullLabel)),
              const DataColumn(label: Text('Total')),
            ],
            rows: [
              for (final gender in CandidateGender.values)
                DataRow(cells: [
                  DataCell(Text(gender.label, style: const TextStyle(fontWeight: FontWeight.bold))),
                  for (final band in bands) DataCell(Text('${counts[gender]![band.fullLabel]}')),
                  DataCell(Text(
                    '${counts[gender]!.values.fold(0, (a, b) => a + b)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  )),
                ]),
              DataRow(cells: [
                const DataCell(Text('All', style: TextStyle(fontWeight: FontWeight.bold))),
                for (final band in bands)
                  DataCell(Text(
                    '${CandidateGender.values.fold(0, (sum, g) => sum + (counts[g]![band.fullLabel] ?? 0))}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  )),
                DataCell(Text('${_scripts.length}', style: const TextStyle(fontWeight: FontWeight.bold))),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultsList(BuildContext context, List<GradeBand> bands) {
    return Card(
      child: Column(
        children: [
          for (final script in _sortedScripts)
            ListTile(
              dense: true,
              leading: CircleAvatar(child: Text('${script.scriptNumber}', style: const TextStyle(fontSize: 12))),
              title: Text('${script.firstName} ${script.surname}'),
              subtitle: Text(script.gender.label),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${_percentFor(script).toStringAsFixed(1)}%',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    classify(_percentFor(script), _system!).fullLabel,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
