import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';
import 'class_overview_screen.dart';
import 'class_setup_screen.dart';

/// Report Form Pipeline, Stage 1 — the "Grade Teacher" home screen. Lists
/// every class already set up on this device (most recent first) and
/// offers "New Class" to start another — tapping an existing class opens
/// [ClassOverviewScreen], the hub for everything else in this pipeline
/// (uploading subject score sheets, the Broad Mark Sheet, report forms).
class GradeTeacherHomeScreen extends StatefulWidget {
  const GradeTeacherHomeScreen({super.key, this.repository});

  final ReportClassRepository? repository;

  @override
  State<GradeTeacherHomeScreen> createState() => _GradeTeacherHomeScreenState();
}

class _GradeTeacherHomeScreenState extends State<GradeTeacherHomeScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  List<ReportClass> _classes = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final classes = await _repository.listClasses();
    if (!mounted) return;
    setState(() {
      _classes = classes;
      _loading = false;
    });
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
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.groups_outlined)),
                        title: Text(reportClass.classGrade),
                        subtitle: Text('${reportClass.schoolName} · ${reportClass.term}'),
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
