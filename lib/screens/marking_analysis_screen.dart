import 'package:flutter/material.dart';

import '../models/grading_scale.dart';
import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/marking_script_repository.dart';
import '../widgets/timed_choice_dialog.dart';

/// AI-Assisted Marking, Stage F — "Analysis": gender-segmented grade-band
/// counts (British Distinction/Merit/Credit/Satisfactory/Fail, or
/// American A-F) across every fully-reviewed script for one marking
/// scheme, plus a results list sortable alphabetically or by rank. Only
/// [MarkingScriptStatus.reviewed] scripts count — same rule as the
/// marksheet export, since anything still [MarkingScriptStatus.graded]
/// hasn't cleared the mandatory teacher review yet.
class MarkingAnalysisScreen extends StatefulWidget {
  const MarkingAnalysisScreen({super.key, required this.scheme, this.scriptRepository});

  final MarkingScheme scheme;
  final MarkingScriptRepository? scriptRepository;

  @override
  State<MarkingAnalysisScreen> createState() => _MarkingAnalysisScreenState();
}

enum _SortMode { rankedHighestFirst, alphabetical }

class _MarkingAnalysisScreenState extends State<MarkingAnalysisScreen> {
  late final MarkingScriptRepository _repository = widget.scriptRepository ?? MarkingScriptRepository();

  bool _loading = true;
  bool _cancelled = false;
  List<MarkingScript> _scripts = [];
  GradingSystem? _system;
  _SortMode _sortMode = _SortMode.rankedHighestFirst;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = (await _repository.loadCatalog()).scripts;
    final scripts = all
        .where((s) => s.schemeId == widget.scheme.id && s.status == MarkingScriptStatus.reviewed && s.gradedAnswers != null)
        .toList();
    if (!mounted) return;
    setState(() {
      _scripts = scripts;
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

  /// gender -> band label -> count, plus the band order itself (so the
  /// table renders highest-band-first regardless of Map iteration order).
  Map<CandidateGender, Map<String, int>> get _counts {
    final system = _system!;
    final counts = <CandidateGender, Map<String, int>>{
      for (final g in CandidateGender.values) g: {for (final b in gradeBandsFor(system)) b.label: 0},
    };
    for (final s in _scripts) {
      final band = classify(_percentFor(s), system);
      counts[s.gender]![band.label] = (counts[s.gender]![band.label] ?? 0) + 1;
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
    return Scaffold(
      appBar: AppBar(title: Text('Analysis — ${widget.scheme.title}')),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.query_stats_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text(
              'No fully-reviewed scripts yet for this scheme. Analysis only counts scripts a teacher has '
              'confirmed as Reviewed/Final.',
              textAlign: TextAlign.center,
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
              for (final band in bands) DataColumn(label: Text(band.label)),
              const DataColumn(label: Text('Total')),
            ],
            rows: [
              for (final gender in CandidateGender.values)
                DataRow(cells: [
                  DataCell(Text(gender.label, style: const TextStyle(fontWeight: FontWeight.bold))),
                  for (final band in bands) DataCell(Text('${counts[gender]![band.label]}')),
                  DataCell(Text(
                    '${counts[gender]!.values.fold(0, (a, b) => a + b)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  )),
                ]),
              DataRow(cells: [
                const DataCell(Text('All', style: TextStyle(fontWeight: FontWeight.bold))),
                for (final band in bands)
                  DataCell(Text(
                    '${CandidateGender.values.fold(0, (sum, g) => sum + (counts[g]![band.label] ?? 0))}',
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
                    classify(_percentFor(script), _system!).label,
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
