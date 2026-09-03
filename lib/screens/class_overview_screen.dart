import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';
import 'broad_mark_sheet_screen.dart';
import 'manage_subjects_screen.dart';
import 'report_form_list_screen.dart';
import 'upload_score_sheet_flow.dart';

/// Report Form Pipeline — the hub for one [ReportClass]: upload subject
/// score sheets (Stages 2-4), manage subject containers including
/// Composite Subjects (Stage 5), and open the Broad Mark Sheet itself
/// (where Stage 6's Omitted Entry and Stage 7's Update Learner Data live).
class ClassOverviewScreen extends StatefulWidget {
  const ClassOverviewScreen({super.key, required this.reportClass, this.repository});

  final ReportClass reportClass;
  final ReportClassRepository? repository;

  @override
  State<ClassOverviewScreen> createState() => _ClassOverviewScreenState();
}

class _ClassOverviewScreenState extends State<ClassOverviewScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  int _learnerCount = 0;
  int _subjectCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final learners = await _repository.listLearners(widget.reportClass.id);
    final subjects = await _repository.listSubjects(widget.reportClass.id);
    if (!mounted) return;
    setState(() {
      _learnerCount = learners.length;
      _subjectCount = subjects.length;
      _loading = false;
    });
  }

  Future<void> _uploadScoreSheet() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UploadScoreSheetFlow(reportClass: widget.reportClass, repository: _repository),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _manageSubjects() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ManageSubjectsScreen(reportClass: widget.reportClass, repository: _repository),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _openReportForms() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportFormListScreen(reportClass: widget.reportClass, repository: _repository),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _openMarkSheet() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BroadMarkSheetScreen(reportClass: widget.reportClass, repository: _repository),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.reportClass.classGrade)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.reportClass.schoolName, style: Theme.of(context).textTheme.titleMedium),
                        Text(widget.reportClass.term, style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 8),
                        Text('$_learnerCount learner(s) on roster · $_subjectCount subject(s) set up'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _actionTile(
                  icon: Icons.upload_file_outlined,
                  title: 'Upload Subject Score Sheets',
                  subtitle: _subjectCount >= ReportClassRepository.maxSubjects
                      ? 'This class already has the maximum of ${ReportClassRepository.maxSubjects} subjects.'
                      : 'Scan or upload a score sheet for one subject at a time.',
                  onTap: _subjectCount >= ReportClassRepository.maxSubjects ? null : _uploadScoreSheet,
                ),
                _actionTile(
                  icon: Icons.grid_on_outlined,
                  title: 'Broad Mark Sheet',
                  subtitle: 'View every learner and subject, edit a learner\'s row, or add one missed on upload.',
                  onTap: _openMarkSheet,
                ),
                _actionTile(
                  icon: Icons.calculate_outlined,
                  title: 'Manage Subjects',
                  subtitle: 'Add subject containers, or set up a Composite Subject (e.g. Science = Physics + Chemistry).',
                  onTap: _manageSubjects,
                ),
                _actionTile(
                  icon: Icons.description_outlined,
                  title: 'Report Forms',
                  subtitle: 'Create, approve & sign, print, and send report forms to parents/guardians.',
                  onTap: _learnerCount == 0 ? null : _openReportForms,
                ),
              ],
            ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Icon(icon)),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
        enabled: onTap != null,
      ),
    );
  }
}
