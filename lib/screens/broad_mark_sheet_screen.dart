import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/report_class.dart';
import '../services/report_class_backup_service.dart';
import '../services/report_class_repository.dart';
import '../services/report_form_document_service.dart';
import 'learner_edit_screen.dart';
import 'omitted_entry_screen.dart';
import 'report_form_list_screen.dart';
import 'subject_analysis_screen.dart';

/// Report Form Pipeline — the Broad Mark Sheet itself: every learner ×
/// every subject container, with each cell's real (or composite-computed)
/// score, learners always shown in alphabetical order. Long-pressing a
/// learner's row is Stage 7 ("Update Learner Data"): a choice of Edit or
/// Delete (delete asks for a second confirmation before it happens — there
/// is no undo). The "Omitted Entry" button is Stage 6: one learner missed
/// during bulk upload, entered manually from scratch. "Proceed" moves on to
/// Report Forms even with entries still unedited or unresolved — nothing
/// here is ever a hard gate. "Mark Report Forms Complete" unlocks the
/// consolidated Analysis table; any score edited after that point is shown
/// in red, with the edit's date/time on tap (see
/// [ReportScore.editedAfterCompletionAt]).
class BroadMarkSheetScreen extends StatefulWidget {
  const BroadMarkSheetScreen({super.key, required this.reportClass, this.repository});

  final ReportClass reportClass;
  final ReportClassRepository? repository;

  @override
  State<BroadMarkSheetScreen> createState() => _BroadMarkSheetScreenState();
}

class _BroadMarkSheetScreenState extends State<BroadMarkSheetScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  final _documentService = ReportFormDocumentService();
  late ReportClass _reportClass = widget.reportClass;
  BroadMarkSheet? _sheet;
  List<ReportLearner> _sortedLearners = const [];
  Map<int, Map<int, double?>> _resolvedScores = {}; // learnerId -> subjectId -> resolved score (composite-aware)
  bool _sharing = false;

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
    final sorted = [...sheet.learners]
      ..sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
    if (!mounted) return;
    setState(() {
      _sheet = sheet;
      _reportClass = sheet.reportClass;
      _sortedLearners = sorted;
      _resolvedScores = resolved;
    });
  }

  Future<void> _handleLongPress(ReportLearner learner) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text('Edit ${learner.fullName}'),
              onTap: () => Navigator.of(sheetContext).pop('edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('Delete ${learner.fullName}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'edit') {
      await _editLearner(learner);
    } else if (choice == 'delete') {
      await _deleteLearner(learner);
    }
  }

  Future<void> _editLearner(ReportLearner learner) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LearnerEditScreen(reportClass: _reportClass, learner: learner, repository: _repository),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _deleteLearner(ReportLearner learner) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sure you want to delete?'),
        content: Text('This permanently removes ${learner.fullName} and every score recorded for them. '
            'This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.deleteLearner(learner.id);
    unawaited(ReportClassBackupService().maybeBackup(_reportClass.id, repository: _repository));
    if (mounted) _load();
  }

  /// Stage 14 — "Print" at the Broad Mark Sheet stage: shares a simple
  /// table document via the OS share sheet (a print app/service commonly
  /// appears there, the same "print via share" pattern already used
  /// everywhere else in this app — no dedicated print plugin exists).
  Future<void> _printOrShare() async {
    final sheet = _sheet;
    if (sheet == null) return;
    setState(() => _sharing = true);
    try {
      final bytes = _documentService.generateBroadMarkSheetDocx(
        reportClass: _reportClass,
        learners: _sortedLearners,
        subjects: sheet.subjects,
        scoresByLearnerThenSubject: _resolvedScores,
      );
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'broad_mark_sheet_${widget.reportClass.id}.docx'));
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        subject: 'Broad Mark Sheet — ${_reportClass.classGrade}',
      ));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _omittedEntry() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OmittedEntryScreen(reportClass: _reportClass, repository: _repository),
      ),
    );
    if (mounted) _load();
  }

  /// The pipeline's next real stage — deliberately never blocked by any
  /// unresolved/unedited entry, per explicit request ("progress the
  /// process to the next stage even if there may be... an unedited
  /// entry").
  Future<void> _proceed() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportFormListScreen(reportClass: _reportClass, repository: _repository),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _markComplete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Mark Report Forms Complete?'),
        content: const Text('This unlocks the consolidated Subject Analysis table. Scores can still be edited '
            'afterwards — any such edit will be shown in red so it stays visible.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Mark Complete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.markReportFormsCompleted(_reportClass.id);
    unawaited(ReportClassBackupService().maybeBackup(_reportClass.id, repository: _repository));
    if (mounted) _load();
  }

  void _openAnalysis() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SubjectAnalysisScreen(reportClass: _reportClass, repository: _repository)),
    );
  }

  DateTime? _editStampFor(int learnerId, ReportSubject subject, BroadMarkSheet sheet) {
    if (!subject.isComposite) {
      return sheet.scoreRowFor(learnerId, subject.id)?.editedAfterCompletionAt;
    }
    final a = subject.compositePartAId == null ? null : sheet.scoreRowFor(learnerId, subject.compositePartAId!)?.editedAfterCompletionAt;
    final b = subject.compositePartBId == null ? null : sheet.scoreRowFor(learnerId, subject.compositePartBId!)?.editedAfterCompletionAt;
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  String _formatDateTime(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  DataCell _scoreCell(ReportLearner learner, ReportSubject subject, BroadMarkSheet sheet) {
    final value = _resolvedScores[learner.id]?[subject.id];
    final text = value?.toStringAsFixed(0) ?? '—';
    final editedAt = _editStampFor(learner.id, subject, sheet);
    if (editedAt == null) {
      return DataCell(Text(text));
    }
    final formatted = _formatDateTime(editedAt);
    return DataCell(
      Tooltip(
        message: 'Edited after report forms were marked complete\n$formatted',
        child: InkWell(
          onTap: () => ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Edited after completion: $formatted'))),
          child: Text(text, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _sheet;
    final isComplete = _reportClass.isReportFormsCompleted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Broad Mark Sheet'),
        actions: [
          if (sheet != null)
            isComplete
                ? IconButton(
                    icon: const Icon(Icons.analytics_outlined),
                    tooltip: 'Subject Analysis',
                    onPressed: _openAnalysis,
                  )
                : IconButton(
                    icon: const Icon(Icons.task_alt),
                    tooltip: 'Mark Report Forms Complete',
                    onPressed: _markComplete,
                  ),
          _sharing
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  icon: const Icon(Icons.print_outlined),
                  tooltip: 'Print / Share',
                  onPressed: _sheet == null ? null : _printOrShare,
                ),
        ],
      ),
      body: sheet == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_reportClass.backupEmail == null)
                  MaterialBanner(
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    content: const Text('No backup email is set for this class — your work here is safe on this '
                        'device, but only a backup email also saves it to a retrievable school-records copy.'),
                    actions: [
                      TextButton(
                        onPressed: () => ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                Expanded(
                  child: _sortedLearners.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No learners yet — upload a subject score sheet to build the roster, or add '
                              'a learner via Omitted Entry.'),
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
                                for (final learner in _sortedLearners)
                                  DataRow(
                                    onLongPress: () => _handleLongPress(learner),
                                    cells: [
                                      DataCell(Text(learner.fullName)),
                                      for (final subject in sheet.subjects) _scoreCell(learner, subject, sheet),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                ),
              ],
            ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'proceed',
            onPressed: _proceed,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Proceed'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'omittedEntry',
            onPressed: _omittedEntry,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Omitted Entry'),
          ),
        ],
      ),
    );
  }
}
