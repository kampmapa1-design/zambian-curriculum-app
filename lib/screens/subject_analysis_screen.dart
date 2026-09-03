import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';
import '../services/report_comment_engine.dart';

/// The consolidated, all-subjects Analysis table — reachable from the
/// Broad Mark Sheet only once its class is marked "Report Forms Complete"
/// (see BroadMarkSheetScreen), per explicit request: one clear table,
/// rather than a subject-by-subject search through the mark sheet itself.
/// One row per subject: how many entries exist, the class high/low/mean,
/// and the pass rate at the same 40-mark boundary [reportGradeFor] already
/// grades 'F' below — kept in sync with that single source of truth rather
/// than a second, independently-chosen pass mark.
class SubjectAnalysisScreen extends StatefulWidget {
  const SubjectAnalysisScreen({super.key, required this.reportClass, this.repository});

  final ReportClass reportClass;
  final ReportClassRepository? repository;

  static const double passMark = 40;

  @override
  State<SubjectAnalysisScreen> createState() => _SubjectAnalysisScreenState();
}

class _SubjectStats {
  const _SubjectStats({required this.subject, required this.scores});

  final ReportSubject subject;
  final List<double> scores;

  int get entries => scores.length;
  double? get highest => scores.isEmpty ? null : scores.reduce((a, b) => a > b ? a : b);
  double? get lowest => scores.isEmpty ? null : scores.reduce((a, b) => a < b ? a : b);
  double? get average => scores.isEmpty ? null : scores.reduce((a, b) => a + b) / scores.length;
  double? get passRate =>
      scores.isEmpty ? null : scores.where((s) => s >= SubjectAnalysisScreen.passMark).length / scores.length * 100;
}

class _SubjectAnalysisScreenState extends State<SubjectAnalysisScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  List<_SubjectStats> _stats = const [];
  int _learnerCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final learners = await _repository.listLearners(widget.reportClass.id);
    final subjects = await _repository.listSubjects(widget.reportClass.id);
    final stats = <_SubjectStats>[];
    for (final subject in subjects) {
      final scores = <double>[];
      for (final learner in learners) {
        final score = await _repository.scoreFor(learner.id, subject, allSubjects: subjects);
        if (score != null) scores.add(score);
      }
      stats.add(_SubjectStats(subject: subject, scores: scores));
    }
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _learnerCount = learners.length;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subject Analysis')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _stats.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No subjects set up yet.'),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${widget.reportClass.label} · $_learnerCount learner(s) on roster',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Pass rate is the share of entered scores at or above ${SubjectAnalysisScreen.passMark.toStringAsFixed(0)} '
                        '(the same boundary the report form\'s own grading uses).',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('Subject')),
                            DataColumn(label: Text('Entries'), numeric: true),
                            DataColumn(label: Text('Highest'), numeric: true),
                            DataColumn(label: Text('Lowest'), numeric: true),
                            DataColumn(label: Text('Average'), numeric: true),
                            DataColumn(label: Text('Pass Rate'), numeric: true),
                          ],
                          rows: [
                            for (final s in _stats)
                              DataRow(cells: [
                                DataCell(Text(s.subject.name)),
                                DataCell(Text('${s.entries}/$_learnerCount')),
                                DataCell(Text(s.highest?.toStringAsFixed(0) ?? '—')),
                                DataCell(Text(s.lowest?.toStringAsFixed(0) ?? '—')),
                                DataCell(Text(s.average?.toStringAsFixed(1) ?? '—')),
                                DataCell(Text(s.passRate == null ? '—' : '${s.passRate!.toStringAsFixed(0)}%')),
                              ]),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text('Overall class average', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(_overallAverageLabel(), style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                ),
    );
  }

  String _overallAverageLabel() {
    final allScores = _stats.expand((s) => s.scores).toList();
    if (allScores.isEmpty) return 'No scores entered yet.';
    final overall = allScores.reduce((a, b) => a + b) / allScores.length;
    return '${overall.toStringAsFixed(1)} across all subjects and learners — ${reportGradeFor(overall)} band';
  }
}
