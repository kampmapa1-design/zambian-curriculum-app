import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../models/timetable.dart';
import '../services/school_service.dart';
import '../services/staffroom_service.dart';
import '../services/timetable_export_service.dart';
import '../services/timetable_service.dart';
import '../services/timetable_share_service.dart';
import 'timetable_grid_widget.dart';

const _kWeekdayLabels = kTimetableWeekdayLabels;

enum _ExportFormat { pdf, csv }

/// Timetable Generation, Stage 4 (grid + conflicts) plus Stages 5 & 7
/// (added 2026-09-14) — tapping a lesson opens a real move/lock dialog.
/// Full drag-and-drop stays Phase 2 per the brief; this is the
/// pick-a-slot equivalent, with the server re-checking every conflict
/// rule before anything is written (see `moveTimetableAssignment`) and
/// a lock that keeps a manually-placed lesson put through later
/// regenerates.
class GeneratedTimetableScreen extends StatefulWidget {
  const GeneratedTimetableScreen({required this.school, super.key});
  final School school;

  @override
  State<GeneratedTimetableScreen> createState() => _GeneratedTimetableScreenState();
}

class _GeneratedTimetableScreenState extends State<GeneratedTimetableScreen> {
  final _timetableService = TimetableService();
  final _schoolService = SchoolService();
  final _exportService = TimetableExportService();
  final _staffroomService = StaffroomService();
  final _shareService = TimetableShareService();
  Map<String, String> _teacherNameByUid = {};
  TimetableConfig? _config;
  SchoolRole? _myRole;
  String _myName = '';
  bool _explaining = false;
  bool _exporting = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadNamesAndConfig();
  }

  bool get _canPin => _myRole?.isLeadership == true || _myRole == SchoolRole.administrator;

  Future<void> _loadNamesAndConfig() async {
    final members = await _schoolService.watchMembers(widget.school.id).first;
    final config = await _timetableService.getConfig(widget.school.id);
    final claim = await _schoolService.currentSchoolClaim();
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    final myName = myUid == null ? '' : members.firstWhere((m) => m.uid == myUid, orElse: () => const SchoolMember(uid: '', name: '', role: SchoolRole.teacher, classIds: [])).name;
    if (!mounted) return;
    setState(() {
      _teacherNameByUid = {for (final m in members) m.uid: m.name};
      _config = config;
      _myRole = claim.role;
      _myName = myName;
    });
  }

  Future<void> _explain() async {
    setState(() => _explaining = true);
    try {
      await _timetableService.explainConflicts(widget.school.id);
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
      builder: (_) => _EditAssignmentDialog(assignment: a, config: config, teacherName: _teacherNameByUid[a.teacherUid] ?? a.teacherUid),
    );
    if (result == null) return;
    try {
      if (result.toggleLock) {
        await _timetableService.setAssignmentLocked(
          schoolId: widget.school.id,
          classId: a.classId,
          subjectName: a.subjectName,
          teacherUid: a.teacherUid,
          day: a.day,
          period: a.period,
          locked: !a.locked,
        );
      } else if (result.newDay != null && result.newPeriod != null) {
        await _timetableService.moveAssignment(
          schoolId: widget.school.id,
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
        await _exportService.exportWholeSchoolPdf(school: widget.school, generated: generated, config: config, teacherNameByUid: _teacherNameByUid);
      } else {
        await _exportService.exportCsv(school: widget.school, assignments: generated.assignments);
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
    setState(() => _busy = true);
    try {
      await _exportService.exportClassPdf(school: widget.school, className: className, assignments: assignments, config: _config!, teacherNameByUid: _teacherNameByUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download started.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pinToStaffroom({String? className, required int periodCount}) async {
    setState(() => _busy = true);
    try {
      await _staffroomService.postPinned(
        schoolId: widget.school.id,
        text: className != null
            ? '📅 $className\'s timetable has been generated — open Timetable → Generated Timetable in the app to view it.'
            : "📅 ${widget.school.name}'s timetable has been generated ($periodCount lessons scheduled) — open Timetable → Generated Timetable in the app to view it.",
        topic: 'Timetable',
        authorName: _myName.isEmpty ? 'Leadership' : _myName,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pinned to Staffroom.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not pin: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareWholeSchoolToWhatsApp(GeneratedTimetable generated, TimetableConfig config) async {
    setState(() => _busy = true);
    try {
      final bytes = await _exportService.buildWholeSchoolPdfBytes(school: widget.school, generated: generated, config: config, teacherNameByUid: _teacherNameByUid);
      await _shareAndReport(bytes, '${widget.school.name}_timetable.pdf', '${widget.school.name} — full timetable');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareClassToWhatsApp(String className, List<TimetableAssignment> assignments) async {
    setState(() => _busy = true);
    try {
      final bytes = await _exportService.buildScopedPdfBytes(
        school: widget.school,
        scopeTitle: className,
        assignments: assignments,
        config: _config!,
        cellSubtitle: (a) => _teacherNameByUid[a.teacherUid] ?? a.teacherUid,
      );
      await _shareAndReport(bytes, '${className}_timetable.pdf', '${widget.school.name} — $className timetable');
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
            stream: _timetableService.watchGenerated(widget.school.id),
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
                  if (_canPin)
                    IconButton(icon: const Icon(Icons.push_pin_outlined), tooltip: 'Pin to Staffroom', onPressed: _busy ? null : () => _pinToStaffroom(periodCount: generated.assignments.length)),
                  IconButton(icon: const Icon(Icons.chat_bubble_outline), tooltip: 'Share to WhatsApp', onPressed: _busy ? null : () => _shareWholeSchoolToWhatsApp(generated, config)),
                  const SizedBox(width: 8),
                ],
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<GeneratedTimetable?>(
        stream: _timetableService.watchGenerated(widget.school.id),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final generated = snapshot.data;
          if (generated == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No timetable has been generated yet.')),
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
                      if (_canPin)
                        IconButton(
                          icon: const Icon(Icons.push_pin_outlined, size: 18),
                          tooltip: 'Pin to Staffroom',
                          onPressed: _busy ? null : () => _pinToStaffroom(className: classNames[classId] ?? classId, periodCount: byClass[classId]!.length),
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
                    cellSubtitle: (a) => _teacherNameByUid[a.teacherUid] ?? a.teacherUid,
                    // Moving/locking a lesson stays web-only (Stage 8's
                    // platform split) — viewing, exporting, pinning, and
                    // sharing this same screen do not, so only the tap
                    // handler itself is gated here.
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

/// Stages 5 & 7 — the confirm-before-apply surface for moving or
/// locking one lesson. Picking a new day/period and pressing "Move"
/// sends it straight to `moveTimetableAssignment`, which re-validates
/// against the live schedule and rejects it (with a specific reason,
/// surfaced as a snackbar by the caller) rather than silently applying
/// an invalid move — this dialog itself doesn't attempt to predict
/// conflicts, only the server's real occupancy data can say for sure.
class _EditAssignmentDialog extends StatefulWidget {
  const _EditAssignmentDialog({required this.assignment, required this.config, required this.teacherName});
  final TimetableAssignment assignment;
  final TimetableConfig config;
  final String teacherName;

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
          Text('Teacher: ${widget.teacherName}'),
          Text('Currently: ${_kWeekdayLabels[a.day]}, period ${a.period + 1}'),
          if (a.locked) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Locked — a regenerate will not move this.', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic))),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _day,
                  decoration: const InputDecoration(labelText: 'Day', isDense: true, border: OutlineInputBorder()),
                  items: [for (var d = 0; d < days; d++) DropdownMenuItem(value: d, child: Text(_kWeekdayLabels[d]))],
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
