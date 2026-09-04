import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';
import '../services/roster_upload_session_repository.dart';
import 'class_overview_screen.dart';
import 'class_setup_screen.dart';

/// Report Form Pipeline, Stage 1 — the "Grade Teacher" home screen. Lists
/// every class already set up on this device (most recent first) and
/// offers "New Class" to start another — tapping an existing class opens
/// [ClassOverviewScreen], the hub for everything else in this pipeline
/// (uploading subject score sheets, the Broad Mark Sheet, report forms).
///
/// Each class shows its real completion status (2026-09-04, per explicit
/// request: "classes that have already been entered and completed should
/// be available for viewing and editing as a full class... before they
/// are dispatched") — a class was always fully viewable/editable via
/// Broad Mark Sheet regardless of stage, but nothing here surfaced WHICH
/// classes were actually done, so finding the right one to review one
/// more time before sending report forms meant opening each one to check.
class GradeTeacherHomeScreen extends StatefulWidget {
  const GradeTeacherHomeScreen({super.key, this.repository});

  final ReportClassRepository? repository;

  @override
  State<GradeTeacherHomeScreen> createState() => _GradeTeacherHomeScreenState();
}

class _GradeTeacherHomeScreenState extends State<GradeTeacherHomeScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  final _rosterSessionRepository = RosterUploadSessionRepository();
  List<ReportClass> _classes = const [];
  Map<int, DateTime?> _rosterCompletedByClass = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final classes = await _repository.listClasses();
    final rosterCompleted = <int, DateTime?>{};
    for (final c in classes) {
      rosterCompleted[c.id] = await _rosterSessionRepository.completedAt(c.id);
    }
    if (!mounted) return;
    setState(() {
      _classes = classes;
      _rosterCompletedByClass = rosterCompleted;
      _loading = false;
    });
  }

  /// The clearest single status label for one class in this list — Report
  /// Forms Complete outranks Roster Upload Complete (it implies the roster
  /// was long since settled), which outranks "still in progress".
  ({String label, Color color, IconData icon}) _statusFor(ReportClass reportClass) {
    if (reportClass.isReportFormsCompleted) {
      return (label: 'Report Forms Complete', color: Colors.green, icon: Icons.verified);
    }
    if (_rosterCompletedByClass[reportClass.id] != null) {
      return (label: 'Roster Upload Complete', color: Colors.amber.shade800, icon: Icons.check_circle_outline);
    }
    return (label: 'In Progress', color: Colors.grey, icon: Icons.hourglass_empty);
  }

  Future<void> _newClass() async {
    final created = await Navigator.of(context).push<ReportClass>(
      MaterialPageRoute(builder: (_) => ClassSetupScreen(repository: _repository)),
    );
    if (created == null || !mounted) return;
    await _openClass(created);
  }

  Future<void> _openClass(ReportClass reportClass) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ClassOverviewScreen(reportClass: reportClass, repository: _repository)),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Grade Teacher')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _classes.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.groups_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 16),
                      const Text(
                        'No classes set up yet. Start one to build its roster, '
                        'Broad Mark Sheet, and report forms.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  itemCount: _classes.length,
                  itemBuilder: (context, index) {
                    final reportClass = _classes[index];
                    final status = _statusFor(reportClass);
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.groups_outlined)),
                        title: Text(reportClass.classGrade),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${reportClass.schoolName} · ${reportClass.term}'),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(status.icon, size: 14, color: status.color),
                                const SizedBox(width: 4),
                                Text(status.label, style: TextStyle(fontSize: 11.5, color: status.color, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ],
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openClass(reportClass),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newClass,
        icon: const Icon(Icons.add),
        label: const Text('Class Setup'),
      ),
    );
  }
}
