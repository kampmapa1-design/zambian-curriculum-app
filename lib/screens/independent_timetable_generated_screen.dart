import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/independent_timetable_project.dart';
import '../models/school.dart';
import '../models/timetable.dart';
import '../services/independent_timetable_service.dart';
import '../services/school_service.dart' show SchoolException;
import '../services/timetable_export_service.dart';
import '../services/timetable_share_service.dart';
import 'timetable_grid_widget.dart';

enum _ExportFormat { pdf, csv }

/// "Build Timetable for Another School" (added 2026-09-16) — view/
/// export/share/edit for one independent project's generated timetable.
/// Deliberately reuses [TimetableGrid], [TimetableExportService], and
/// [TimetableShareService] unchanged (all three are pure/display-only —
/// no School Network dependency) against a synthetic [School] built
/// purely for labelling PDFs/filenames, never written to Firestore.
///
/// Staffroom pinning is dropped entirely (an independent project has no
/// Staffroom to pin to); everything else School Network's real
/// Generated Timetable screen does — AI conflict explanation, tap-to-
/// move/lock editing (web-only, same platform split as the real
/// screen), view, export, WhatsApp share — works the same way here.
class IndependentTimetableGeneratedScreen extends StatefulWidget {
  const IndependentTimetableGeneratedScreen({required this.project, super.key});
  final IndependentTimetableProject project;

  @override
  State<IndependentTimetableGeneratedScreen> createState() => _IndependentTimetableGeneratedScreenState();
}

class _IndependentTimetableGeneratedScreenState extends State<IndependentTimetableGeneratedScreen> {
  final _service = IndependentTimetableService();
  final _exportService = TimetableExportService();
  final _shareService = TimetableShareService();
  TimetableConfig? _config;
  bool _exporting = false;
  bool _busy = false;
  bool _explaining = false;

  School get _syntheticSchool => School(
        id: widget.project.id,
        name: widget.project.institutionName,
        province: '',
        district: '',
        headTeacherName: '',
        code: '',
        institutionalSubscription: false,
      );

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await _service.getConfig(widget.project.id);
    if (!mounted) return;
    setState(() => _config = config);
  }

  Future<void> _explain() async {
    setState(() => _explaining = true);
    try {
      await _service.explainConflicts(widget.project.id);
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _explaining = false);
    }
  }

  Future<void> _editAssignment(TimetableAssignment a, TimetableConfig config) async {
    final result = await showDialog<_EditChoice>(
      context: context,
      builder: (_) => _EditAssignmentDialog(assignment: a, config: config),
    );
    if (result == null) return;
    try {
      if (result.toggleLock) {
        await _service.setAssignmentLocked(
          projectId: widget.project.id,
          classId: a.classId,
          subjectName: a.subjectName,
          teacherUid: a.teacherUid,
          day: a.day,
          period: a.period,
          locked: !a.locked,
        );
      } else if (result.newDay != null && result.newPeriod != null) {
        await _service.moveAssignment(
          projectId: widget.project.id,
          classId: a.classId,
          subjectName: a.subjectName,
          teacherUid: a.teacherUid,
          day: a.day,
          period: a.period,
          newDay: result.newDay!,
          newPeriod: result.newPeriod!,
        );
      }
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _export(GeneratedTimetable generated, TimetableConfig config) async {
    final format = await showDialog<_ExportFormat>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Export timetable'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_ExportFormat.pdf),
            child: const Row(children: [Icon(Icons.picture_as_pdf_outlined), SizedBox(width: 12), Text('PDF (one page per class)')]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_ExportFormat.csv),
            child: const Row(children: [Icon(Icons.table_chart_outlined), SizedBox(width: 12), Text('CSV (spreadsheet)')]),
          ),
        ],
      ),
    );
    if (format == null) return;
    setState(() => _exporting = true);
    try {
      if (format == _ExportFormat.pdf) {
        await _exportService.exportWholeSchoolPdf(school: _syntheticSchool, generated: generated, config: config, teacherNameByUid: const {});
      } else {
        await _exportService.exportCsv(school: _syntheticSchool, assignments: generated.assignments);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download started.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export: $e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportClass(String className, List<TimetableAssignment> assignments) async {
    if (_config == null) return;
    setState(() => _busy = true);
    try {
      await _exportService.exportClassPdf(school: _syntheticSchool, className: className, assignments: assignments, config: _config!, teacherNameByUid: const {});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download started.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareWholeSchoolToWhatsApp(GeneratedTimetable generated, TimetableConfig config) async {
    setState(() => _busy = true);
    try {
      final bytes = await _exportService.buildWholeSchoolPdfBytes(school: _syntheticSchool, generated: generated, config: config, teacherNameByUid: const {});
      await _shareAndReport(bytes, '${widget.project.institutionName}_timetable.pdf', '${widget.project.institutionName} — full timetable');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareClassToWhatsApp(String className, List<TimetableAssignment> assignments) async {
    if (_config == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await _exportService.buildScopedPdfBytes(
        school: _syntheticSchool,
        scopeTitle: className,
        assignments: assignments,
        config: _config!,
        cellSubtitle: (a) => a.teacherUid,
      );
      await _shareAndReport(bytes, '${className}_timetable.pdf', '${widget.project.institutionName} — $className timetable');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareAndReport(Uint8List bytes, String fileName, String caption) async {
    final outcome = await _shareService.shareToWhatsApp(bytes: bytes, fileName: fileName, caption: caption);
    if (!mounted) return;
    if (outcome == TimetableShareOutcome.webDownloadedAndWhatsAppOpened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Downloaded and WhatsApp opened — attach the downloaded file to your chat.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Generated Timetable'),
        actions: [
          StreamBuilder<GeneratedTimetable?>(
            stream: _service.watchGenerated(widget.project.id),
            builder: (context, snapshot) {
              final generated = snapshot.data;
              final config = _config;
              if (generated == null || config == null) return const SizedBox.shrink();
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    icon: _exporting ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Icon(Icons.ios_share),
                    label: const Text('Export'),
                    onPressed: _exporting ? null : () => _export(generated, config),
                  ),
                  IconButton(icon: const Icon(Icons.chat_bubble_outline), tooltip: 'Share to WhatsApp', onPressed: _busy ? null : () => _shareWholeSchoolToWhatsApp(generated, config)),
                  const SizedBox(width: 8),
                ],
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<GeneratedTimetable?>(
        stream: _service.watchGenerated(widget.project.id),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final generated = snapshot.data;
          if (generated == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No timetable has been generated yet. Go to Timetable Setup and run the generator.')),
            );
          }
          final config = _config;
          final byClass = <String, List<TimetableAssignment>>{};
          final classNames = <String, String>{};
          for (final a in generated.assignments) {
            (byClass[a.classId] ??= []).add(a);
            classNames[a.classId] = a.className;
          }
          final classIds = byClass.keys.toList()..sort((a, b) => (classNames[a] ?? '').compareTo(classNames[b] ?? ''));

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (generated.conflicts.isNotEmpty) ...[
                Card(
                  color: Colors.amber.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.warning_amber_outlined, color: Colors.amber.shade900),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${generated.conflicts.length} unresolved conflict${generated.conflicts.length == 1 ? '' : 's'}',
                                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber.shade900),
                              ),
                            ),
                            TextButton.icon(
                              icon: _explaining
                                  ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.auto_awesome_outlined, size: 16),
                              label: Text(_explaining ? 'Explaining...' : 'Explain with AI'),
                              onPressed: _explaining ? null : _explain,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (var i = 0; i < generated.conflicts.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('• ${generated.conflicts[i].description}', style: const TextStyle(fontSize: 12.5)),
                                for (final ex in generated.conflictExplanations.where((e) => e.conflictIndex == i))
                                  Padding(
                                    padding: const EdgeInsets.only(left: 14, top: 4),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(ex.explanation, style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                                        Text('Suggested fix: ${ex.suggestedFix}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (config == null)
                const Center(child: CircularProgressIndicator())
              else
                for (final classId in classIds) ...[
                  Row(
                    children: [
                      Expanded(child: Text(classNames[classId] ?? classId, style: Theme.of(context).textTheme.titleMedium)),
                      IconButton(
                        icon: const Icon(Icons.ios_share, size: 18),
                        tooltip: 'Export',
                        onPressed: _busy ? null : () => _exportClass(classNames[classId] ?? classId, byClass[classId]!),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chat_bubble_outline, size: 18),
                        tooltip: 'Share to WhatsApp',
                        onPressed: _busy ? null : () => _shareClassToWhatsApp(classNames[classId] ?? classId, byClass[classId]!),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TimetableGrid(
                    assignments: byClass[classId]!,
                    periodsPerDay: config.periodsPerDay,
                    teachingDaysPerWeek: config.teachingDaysPerWeek,
                    // The "teacherUid" here IS the teacher's typed name
                    // (see IndependentTimetableClass's doc comment) —
                    // shown as-is, no member lookup needed or possible.
                    cellSubtitle: (a) => a.teacherUid,
                    // Moving/locking a lesson stays web-only, same
                    // platform split as the real Generated Timetable
                    // screen (see its own onCellTap comment).
                    onCellTap: kIsWeb ? (a) => _editAssignment(a, config) : null,
                  ),
                  const SizedBox(height: 24),
                ],
            ],
          );
        },
      ),
    );
  }
}

class _EditChoice {
  const _EditChoice({this.newDay, this.newPeriod, this.toggleLock = false});
  final int? newDay;
  final int? newPeriod;
  final bool toggleLock;
}

/// Mirrors [GeneratedTimetableScreen]'s own edit dialog, minus a separate
/// `teacherName` field — here `assignment.teacherUid` already IS the
/// display name (see the module doc comment), so there's no lookup to
/// pass in separately.
class _EditAssignmentDialog extends StatefulWidget {
  const _EditAssignmentDialog({required this.assignment, required this.config});
  final TimetableAssignment assignment;
  final TimetableConfig config;

  @override
  State<_EditAssignmentDialog> createState() => _EditAssignmentDialogState();
}

class _EditAssignmentDialogState extends State<_EditAssignmentDialog> {
  late int _day = widget.assignment.day;
  late int _period = widget.assignment.period;

  @override
  Widget build(BuildContext context) {
    final a = widget.assignment;
    final days = widget.config.teachingDaysPerWeek.clamp(0, 7);
    return AlertDialog(
      title: Text('${a.subjectName} — ${a.className}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Teacher: ${a.teacherUid}'),
          Text('Currently: ${kTimetableWeekdayLabels[a.day]}, period ${a.period + 1}'),
          if (a.locked) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Locked — a regenerate will not move this.', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic))),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _day,
                  decoration: const InputDecoration(labelText: 'Day', isDense: true, border: OutlineInputBorder()),
                  items: [for (var d = 0; d < days; d++) DropdownMenuItem(value: d, child: Text(kTimetableWeekdayLabels[d]))],
                  onChanged: (v) => setState(() => _day = v ?? _day),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _period,
                  decoration: const InputDecoration(labelText: 'Period', isDense: true, border: OutlineInputBorder()),
                  items: [for (var p = 0; p < widget.config.periodsPerDay; p++) DropdownMenuItem(value: p, child: Text('${p + 1}'))],
                  onChanged: (v) => setState(() => _period = v ?? _period),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(const _EditChoice(toggleLock: true)),
          child: Text(a.locked ? 'Unlock' : 'Lock in place'),
        ),
        FilledButton(
          onPressed: (_day == a.day && _period == a.period) ? null : () => Navigator.of(context).pop(_EditChoice(newDay: _day, newPeriod: _period)),
          child: const Text('Move'),
        ),
      ],
    );
  }
}
