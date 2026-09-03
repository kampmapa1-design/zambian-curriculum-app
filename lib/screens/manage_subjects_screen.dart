import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';

/// Report Form Pipeline, Stage 5 — Broad Mark Sheet subject containers (up
/// to 12 per class). A plain subject is created automatically the first
/// time a score sheet is uploaded for it (see UploadScoreSheetFlow); this
/// screen is where a Composite Subject gets set up — e.g. "Science" as an
/// auto-computed sum of two already-existing plain subjects (Physics +
/// Chemistry), never manually editable once created.
class ManageSubjectsScreen extends StatefulWidget {
  const ManageSubjectsScreen({super.key, required this.reportClass, this.repository});

  final ReportClass reportClass;
  final ReportClassRepository? repository;

  @override
  State<ManageSubjectsScreen> createState() => _ManageSubjectsScreenState();
}

class _ManageSubjectsScreenState extends State<ManageSubjectsScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  List<ReportSubject> _subjects = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final subjects = await _repository.listSubjects(widget.reportClass.id);
    if (!mounted) return;
    setState(() {
      _subjects = subjects;
      _loading = false;
    });
  }

  Future<void> _addPlainSubject() async {
    final name = await _promptForName('New subject name');
    if (name == null || name.trim().isEmpty) return;
    try {
      await _repository.getOrCreateSubject(widget.reportClass.id, name);
      await _load();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<String?> _promptForName(String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text), child: const Text('Add')),
        ],
      ),
    );
  }

  Future<void> _addCompositeSubject() async {
    final plainSubjects = _subjects.where((s) => !s.isComposite).toList();
    if (plainSubjects.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least 2 plain subjects first — a Composite Subject sums two of them.')),
      );
      return;
    }
    final result = await showDialog<({String name, ReportSubject a, ReportSubject b})>(
      context: context,
      builder: (dialogContext) => _CompositeSubjectDialog(candidates: plainSubjects),
    );
    if (result == null) return;
    try {
      await _repository.createCompositeSubject(
        classId: widget.reportClass.id,
        name: result.name,
        partA: result.a,
        partB: result.b,
      );
      await _load();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Subjects')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Text('${_subjects.length} of ${ReportClassRepository.maxSubjects} subjects used',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                for (final subject in _subjects)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(subject.isComposite ? Icons.calculate_outlined : Icons.menu_book_outlined),
                      title: Text(subject.name),
                      subtitle: subject.isComposite
                          ? Text('Composite — auto-sum of ${_partName(subject.compositePartAId)} + '
                              '${_partName(subject.compositePartBId)}')
                          : const Text('Plain subject'),
                    ),
                  ),
                if (_subjects.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No subjects yet — they\'re created automatically the first time you upload a score '
                      'sheet for one, or you can add one here.',
                    ),
                  ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _subjects.length >= ReportClassRepository.maxSubjects ? null : _addPlainSubject,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Subject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _subjects.length >= ReportClassRepository.maxSubjects ? null : _addCompositeSubject,
                  icon: const Icon(Icons.calculate_outlined),
                  label: const Text('Composite Subject'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _partName(int? id) => _subjects.where((s) => s.id == id).map((s) => s.name).firstOrNull ?? '?';
}

class _CompositeSubjectDialog extends StatefulWidget {
  const _CompositeSubjectDialog({required this.candidates});
  final List<ReportSubject> candidates;

  @override
  State<_CompositeSubjectDialog> createState() => _CompositeSubjectDialogState();
}

class _CompositeSubjectDialogState extends State<_CompositeSubjectDialog> {
  final _nameController = TextEditingController(text: 'Science');
  ReportSubject? _a;
  ReportSubject? _b;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _canCreate => _nameController.text.trim().isNotEmpty && _a != null && _b != null && _a != _b;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Composite Subject'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ReportSubject>(
            initialValue: _a,
            decoration: const InputDecoration(labelText: 'First part', border: OutlineInputBorder()),
            items: [for (final s in widget.candidates) DropdownMenuItem(value: s, child: Text(s.name))],
            onChanged: (v) => setState(() => _a = v),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ReportSubject>(
            initialValue: _b,
            decoration: const InputDecoration(labelText: 'Second part', border: OutlineInputBorder()),
            items: [for (final s in widget.candidates) DropdownMenuItem(value: s, child: Text(s.name))],
            onChanged: (v) => setState(() => _b = v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _canCreate
              ? () => Navigator.of(context).pop((name: _nameController.text, a: _a!, b: _b!))
              : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
