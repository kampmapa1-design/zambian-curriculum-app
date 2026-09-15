import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';

/// Stage 7 of School Network (added 2026-09-13) — "a sample report form
/// (the first learner on that class's Broad Mark Sheet) as a live preview
/// of current progress." A genuine in-app read-only preview, computed
/// fresh from current data every time it opens (not a cached/exported
/// document) — the roster's first learner in roster order, same ordering
/// [ReportClassRepository.loadBroadMarkSheet] already returns.
class ClassReportPreviewScreen extends StatefulWidget {
  const ClassReportPreviewScreen({required this.reportClass, this.repository, super.key});

  final ReportClass reportClass;
  final ReportClassRepository? repository;

  @override
  State<ClassReportPreviewScreen> createState() => _ClassReportPreviewScreenState();
}

class _ClassReportPreviewScreenState extends State<ClassReportPreviewScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  bool _loading = true;
  ReportLearner? _learner;
  List<ReportSubject> _subjects = const [];
  Map<int, double?> _scores = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sheet = await _repository.loadBroadMarkSheet(widget.reportClass.id);
    ReportLearner? firstLearner;
    final scores = <int, double?>{};
    if (sheet.learners.isNotEmpty) {
      firstLearner = sheet.learners.first;
      for (final subject in sheet.subjects) {
        scores[subject.id] = await _repository.scoreFor(firstLearner.id, subject, allSubjects: sheet.subjects);
      }
    }
    if (!mounted) return;
    setState(() {
      _learner = firstLearner;
      _subjects = sheet.subjects;
      _scores = scores;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Preview — ${widget.reportClass.classGrade}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _learner == null
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No learners on this class\'s roster yet.')),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.visibility_outlined, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Live preview of the first learner on the roster (${_learner!.fullName}) — refreshes with current data every time you open this, not a saved snapshot.',
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(_learner!.fullName, style: Theme.of(context).textTheme.titleLarge),
                    Text('${widget.reportClass.classGrade} · ${widget.reportClass.term}'),
                    const SizedBox(height: 16),
                    Table(
                      border: TableBorder.all(color: Theme.of(context).colorScheme.outlineVariant),
                      columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(1)},
                      children: [
                        TableRow(
                          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                          children: const [
                            Padding(padding: EdgeInsets.all(8), child: Text('Subject', style: TextStyle(fontWeight: FontWeight.bold))),
                            Padding(padding: EdgeInsets.all(8), child: Text('Score', style: TextStyle(fontWeight: FontWeight.bold))),
                          ],
                        ),
                        for (final subject in _subjects)
                          TableRow(
                            children: [
                              Padding(padding: const EdgeInsets.all(8), child: Text(subject.name)),
                              Padding(padding: const EdgeInsets.all(8), child: Text(_scores[subject.id]?.toStringAsFixed(0) ?? '—')),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
    );
  }
}
