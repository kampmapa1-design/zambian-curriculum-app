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
  bool _saving = false;

  @override
  void dispose() {
    _schoolNameController.dispose();
    _classGradeController.dispose();
    _termController.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _schoolNameController.text.trim().isNotEmpty &&
      _classGradeController.text.trim().isNotEmpty &&
      _termController.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final created = await _repository.createClass(
      schoolName: _schoolNameController.text,
      classGrade: _classGradeController.text,
      term: _termController.text,
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
