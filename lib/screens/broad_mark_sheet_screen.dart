import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';
import 'learner_edit_screen.dart';
import 'omitted_entry_screen.dart';

/// Report Form Pipeline — the Broad Mark Sheet itself: every learner ×
/// every subject container, with each cell's real (or composite-computed)
/// score. Long-pressing a learner's row is Stage 7 ("Update Learner
/// Data"): an "Edit?" confirmation, then that one learner's row opens for
/// editing across every subject, without touching anyone else's data. The
/// "Omitted Entry" button is Stage 6: one learner missed during bulk
/// upload, entered manually from scratch.
class BroadMarkSheetScreen extends StatefulWidget {
  const BroadMarkSheetScreen({super.key, required this.reportClass, this.repository});

  final ReportClass reportClass;
  final ReportClassRepository? repository;

  @override
  State<BroadMarkSheetScreen> createState() => _BroadMarkSheetScreenState();
}

class _BroadMarkSheetScreenState extends State<BroadMarkSheetScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  BroadMarkSheet? _sheet;
  Map<int, Map<int, double?>> _resolvedScores = {}; // learnerId -> subjectId -> resolved score (composite-aware)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sheet = await _repository.loadBroadMarkSheet(widget.reportClass.id);
    final resolved = <int, Map<int, double?>>{};
    for (final learner in sheet.learners) {
      final row = <int, double?>{};
      for (final subject in sheet.subjects) {
        row[subject.id] = await _repository.scoreFor(learner.id, subject, allSubjects: sheet.subjects);
      }
      resolved[learner.id] = row;
    }
    if (!mounted) return;
    setState(() {
      _sheet = sheet;
      _resolvedScores = resolved;
    });
  }

  Future<void> _confirmEdit(ReportLearner learner) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit?'),
        content: Text('Edit ${learner.fullName}\'s scores across every subject?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Edit')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LearnerEditScreen(reportClass: widget.reportClass, learner: learner, repository: _repository),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _omittedEntry() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OmittedEntryScreen(reportClass: widget.reportClass, repository: _repository),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _sheet;
    return Scaffold(
      appBar: AppBar(title: const Text('Broad Mark Sheet')),
      body: sheet == null
          ? const Center(child: CircularProgressIndicator())
          : sheet.learners.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No learners yet — upload a subject score sheet to build the roster, or add a '
                      'learner via Omitted Entry.'),
                )
              : SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: [
                        const DataColumn(label: Text('Learner')),
                        for (final subject in sheet.subjects) DataColumn(label: Text(subject.name)),
                      ],
                      rows: [
                        for (final learner in sheet.learners)
                          DataRow(
                            onLongPress: () => _confirmEdit(learner),
                            cells: [
                              DataCell(Text(learner.fullName)),
                              for (final subject in sheet.subjects)
                                DataCell(Text(_resolvedScores[learner.id]?[subject.id]?.toStringAsFixed(0) ?? '—')),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _omittedEntry,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Omitted Entry'),
      ),
    );
  }
}
