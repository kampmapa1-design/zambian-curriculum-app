import 'package:flutter/material.dart';

import '../models/independent_timetable_project.dart';
import '../services/independent_timetable_service.dart';
import '../services/school_service.dart' show SchoolException;
import 'independent_timetable_entry_from_photo_screen.dart';

/// "Build Timetable for Another School" (added 2026-09-16) — the class
/// roster for one independent project. Stands in for School Network's
/// real class-connection flow, which fundamentally needs real
/// registered Grade Teacher accounts and doesn't fit here: every class,
/// subject, and "who teaches it" is entered directly by the one teacher
/// building this draft, with the teacher identified by a plain typed
/// name (see [IndependentTimetableClass]'s doc comment for why).
class IndependentTimetableClassesScreen extends StatefulWidget {
  const IndependentTimetableClassesScreen({required this.project, super.key});
  final IndependentTimetableProject project;

  @override
  State<IndependentTimetableClassesScreen> createState() => _IndependentTimetableClassesScreenState();
}

class _IndependentTimetableClassesScreenState extends State<IndependentTimetableClassesScreen> {
  final _service = IndependentTimetableService();

  Future<void> _openEditor({IndependentTimetableClass? existing}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _ClassEditorScreen(projectId: widget.project.id, existing: existing)),
    );
  }

  Future<void> _delete(IndependentTimetableClass cls) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this class?'),
        content: Text('"${cls.classGrade}" and its subject/teacher assignments will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.deleteClass(projectId: widget.project.id, classId: cls.id);
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Classes & Subjects')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Add class'),
      ),
      body: StreamBuilder<List<IndependentTimetableClass>>(
        stream: _service.watchClasses(widget.project.id),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final classes = snapshot.data!;
          if (classes.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No classes yet. Tap "Add class" to add one — e.g. "Form 1A" — with its subjects and who teaches each one.')),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            itemCount: classes.length,
            itemBuilder: (context, index) {
              final cls = classes[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.class_outlined),
                  title: Text(cls.classGrade),
                  subtitle: Text(cls.subjectNames.isEmpty ? 'No subjects yet' : cls.subjectNames.join(', ')),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.camera_alt_outlined),
                        tooltip: 'Set up from a photo of the existing timetable',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => IndependentTimetableEntryFromPhotoScreen(project: widget.project, schoolClass: cls)),
                        ),
                      ),
                      IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: () => _delete(cls)),
                    ],
                  ),
                  onTap: () => _openEditor(existing: cls),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ClassEditorScreen extends StatefulWidget {
  const _ClassEditorScreen({required this.projectId, this.existing});
  final String projectId;
  final IndependentTimetableClass? existing;

  @override
  State<_ClassEditorScreen> createState() => _ClassEditorScreenState();
}

class _ClassEditorScreenState extends State<_ClassEditorScreen> {
  final _service = IndependentTimetableService();
  late final _classGradeController = TextEditingController(text: widget.existing?.classGrade ?? '');
  final _newSubjectController = TextEditingController();
  bool _saving = false;

  // subject name -> teacher name controller.
  final Map<String, TextEditingController> _teacherControllers = {};
  List<String> _subjectOrder = [];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _subjectOrder = List.of(existing.subjectNames);
      for (final s in _subjectOrder) {
        _teacherControllers[s] = TextEditingController(text: existing.subjectTeacherNames[s] ?? '');
      }
    }
  }

  @override
  void dispose() {
    _classGradeController.dispose();
    _newSubjectController.dispose();
    for (final c in _teacherControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _addSubject() {
    final name = _newSubjectController.text.trim();
    if (name.isEmpty || _teacherControllers.containsKey(name)) return;
    setState(() {
      _teacherControllers[name] = TextEditingController();
      _subjectOrder = [..._subjectOrder, name];
      _newSubjectController.clear();
    });
  }

  void _removeSubject(String name) {
    setState(() {
      _teacherControllers.remove(name)?.dispose();
      _subjectOrder.remove(name);
    });
  }

  Future<void> _save() async {
    final classGrade = _classGradeController.text.trim();
    if (classGrade.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('A class name is required, e.g. "Form 1A".')));
      return;
    }
    setState(() => _saving = true);
    try {
      final subjectTeacherNames = <String, String>{
        for (final s in _subjectOrder) s: _teacherControllers[s]?.text.trim() ?? '',
      };
      await _service.saveClass(
        projectId: widget.projectId,
        classId: widget.existing?.id,
        classGrade: classGrade,
        subjectNames: _subjectOrder,
        subjectTeacherNames: subjectTeacherNames,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Add class' : 'Edit class'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _saving
                ? const Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4)))
                : TextButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _classGradeController,
            decoration: const InputDecoration(labelText: 'Class name', hintText: 'e.g. Form 1A', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          Text('Subjects & teachers', style: Theme.of(context).textTheme.titleMedium),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Type each subject and who teaches it. Spell a teacher\'s name exactly the same way across every class '
              'they teach, so the generator knows it\'s the same person and never double-books them.',
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ),
          for (final subject in _subjectOrder)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(flex: 2, child: Text(subject)),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _teacherControllers[subject],
                      decoration: const InputDecoration(labelText: 'Teacher name', isDense: true, border: OutlineInputBorder()),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _removeSubject(subject)),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newSubjectController,
                  decoration: const InputDecoration(labelText: 'Add subject', isDense: true, border: OutlineInputBorder()),
                  onSubmitted: (_) => _addSubject(),
                ),
              ),
              IconButton(icon: const Icon(Icons.add), onPressed: _addSubject),
            ],
          ),
        ],
      ),
    );
  }
}
