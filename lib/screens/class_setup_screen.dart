import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';

/// Report Form Pipeline, Stage 1 — Class Setup: School Name, Class/Grade,
/// Term. Creates a [ReportClass] with an empty roster (max 140 learners,
/// established later — see Stage 2/ReportClassRepository.matchNamesAgainstRoster)
/// and pops it back to the caller.
class ClassSetupScreen extends StatefulWidget {
  const ClassSetupScreen({super.key, this.repository});

  final ReportClassRepository? repository;

  @override
  State<ClassSetupScreen> createState() => _ClassSetupScreenState();
}

class _ClassSetupScreenState extends State<ClassSetupScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  final _schoolNameController = TextEditingController();
  final _classGradeController = TextEditingController();
  final _termController = TextEditingController();
  final _backupEmailController = TextEditingController();
  ReportAssessmentSystem _assessmentSystem = ReportAssessmentSystem.standaloneTest;
  bool _saving = false;

  @override
  void dispose() {
    _schoolNameController.dispose();
    _classGradeController.dispose();
    _termController.dispose();
    _backupEmailController.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _schoolNameController.text.trim().isNotEmpty &&
      _classGradeController.text.trim().isNotEmpty &&
      _termController.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final backupEmail = _backupEmailController.text.trim();
    final created = await _repository.createClass(
      schoolName: _schoolNameController.text,
      classGrade: _classGradeController.text,
      term: _termController.text,
      assessmentSystem: _assessmentSystem,
      backupEmail: backupEmail.isEmpty ? null : backupEmail,
    );
    if (!mounted) return;
    Navigator.of(context).pop<ReportClass>(created);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Class Setup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Set up a new class — its roster starts empty and builds itself from your first '
              'subject score-sheet upload.'),
          const SizedBox(height: 20),
          TextField(
            controller: _schoolNameController,
            decoration: const InputDecoration(labelText: 'School Name', border: OutlineInputBorder()),
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _classGradeController,
            decoration: const InputDecoration(
              labelText: 'Class / Grade',
              hintText: 'e.g. Grade 10A',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _termController,
            decoration: const InputDecoration(
              labelText: 'Term',
              hintText: 'e.g. Term 3, 2026',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 24),
          Text('Will the Continuous Assessment (C.A) system be used, or is it a standalone test?',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'This decides how score entry and the report form itself are laid out for this class — '
            'C.A. splits every subject into a weighted Test + End-of-Term Exam; a standalone test is '
            'one score per subject. You can confirm the C.A. weighting (e.g. 40/60 or 50/50) when score '
            'entry actually starts.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ReportAssessmentSystem>(
            segments: const [
              ButtonSegment(
                value: ReportAssessmentSystem.continuousAssessment,
                label: Text('Continuous Assessment'),
                icon: Icon(Icons.stacked_line_chart),
              ),
              ButtonSegment(
                value: ReportAssessmentSystem.standaloneTest,
                label: Text('Standalone Test'),
                icon: Icon(Icons.edit_note),
              ),
            ],
            selected: {_assessmentSystem},
            onSelectionChanged: (selection) => setState(() => _assessmentSystem = selection.first),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _backupEmailController,
            decoration: const InputDecoration(
              labelText: 'Backup Email (optional)',
              hintText: 'A school-records email to save this class\'s data to',
              helperText: 'Recommended — every score-sheet upload and edit will also save a copy here, on '
                  'top of the copy that always stays on this device. You can add this later if you skip it now.',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.email_outlined),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _canSave && !_saving ? _save : null,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            label: Text(_saving ? 'Setting up…' : 'Create Class'),
          ),
        ),
      ),
    );
  }
}
