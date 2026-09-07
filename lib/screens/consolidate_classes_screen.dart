import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';
import 'broad_mark_sheet_screen.dart';

/// "Consolidate" (2026-09-08, per explicit request): reached from the
/// Broad Mark Sheet's own AppBar — lets a teacher pick one or more OTHER
/// existing class/cohort lists that really represent the same physical
/// class (scores entered as separate uploads/sessions, or a class that
/// was accidentally set up more than once) and merge them, together with
/// the class this screen was opened from, into one brand-new consolidated
/// class — see [ReportClassRepository.consolidateClasses] for exactly how
/// learners/subjects/scores are merged and put in order. Every source
/// class is left completely untouched.
class ConsolidateClassesScreen extends StatefulWidget {
  const ConsolidateClassesScreen({super.key, required this.currentClass, this.repository});

  final ReportClass currentClass;
  final ReportClassRepository? repository;

  @override
  State<ConsolidateClassesScreen> createState() => _ConsolidateClassesScreenState();
}

class _ConsolidateClassesScreenState extends State<ConsolidateClassesScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  bool _loading = true;
  List<ReportClass> _otherClasses = const [];
  final Set<int> _selectedIds = {};
  bool _consolidating = false;

  late final _schoolNameController = TextEditingController(text: widget.currentClass.schoolName);
  late final _classGradeController = TextEditingController(text: widget.currentClass.classGrade);
  late final _termController = TextEditingController(text: widget.currentClass.term);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _repository.listClasses();
    if (!mounted) return;
    setState(() {
      _otherClasses = all.where((c) => c.id != widget.currentClass.id).toList();
      _loading = false;
    });
  }

  @override
  void dispose() {
    _schoolNameController.dispose();
    _classGradeController.dispose();
    _termController.dispose();
    super.dispose();
  }

  Future<void> _consolidate() async {
    if (_selectedIds.isEmpty) return;
    setState(() => _consolidating = true);
    try {
      final newClass = await _repository.consolidateClasses(
        sourceClassIds: [widget.currentClass.id, ..._selectedIds],
        schoolName: _schoolNameController.text,
        classGrade: _classGradeController.text,
        term: _termController.text,
      );
      if (!mounted) return;
      // Replaces this screen AND the Broad Mark Sheet it was opened from
      // with the new consolidated class's own Broad Mark Sheet — the
      // source lists this was built from are untouched and still reachable
      // from Grade Teacher's own class list, exactly as before.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => BroadMarkSheetScreen(reportClass: newClass, repository: _repository),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Could not consolidate'),
          content: Text('$error'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK')),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _consolidating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Consolidate Class Lists')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                Text(
                  'Merges "${widget.currentClass.label}" with whichever other lists below you confirm are '
                  'really the same class/cohort — into one brand-new list with every real learner and score, '
                  'put in alphabetical order. The lists you pick here are left exactly as they are; nothing is '
                  'deleted.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 16),
                Text('New consolidated list details', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _schoolNameController,
                  decoration: const InputDecoration(labelText: 'School Name', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _classGradeController,
                  decoration: const InputDecoration(labelText: 'Class/Grade', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _termController,
                  decoration: const InputDecoration(labelText: 'Term', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 20),
                Text('Pick the other list(s) to merge in', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                if (_otherClasses.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No other class lists exist yet — nothing to consolidate with.'),
                  )
                else
                  for (final c in _otherClasses)
                    CheckboxListTile(
                      value: _selectedIds.contains(c.id),
                      onChanged: (checked) => setState(() {
                        if (checked ?? false) {
                          _selectedIds.add(c.id);
                        } else {
                          _selectedIds.remove(c.id);
                        }
                      }),
                      title: Text(c.label),
                      subtitle: Text(
                        c.isContinuousAssessment ? 'Continuous Assessment' : 'Standalone test',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: (_selectedIds.isEmpty || _consolidating) ? null : _consolidate,
            icon: _consolidating
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.call_merge),
            label: Text(_selectedIds.isEmpty
                ? 'Pick at least one other list'
                : 'Consolidate ${_selectedIds.length + 1} lists'),
          ),
        ),
      ),
    );
  }
}
