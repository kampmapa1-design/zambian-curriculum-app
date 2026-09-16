import 'package:flutter/material.dart';

import '../models/independent_timetable_project.dart';
import '../services/independent_timetable_service.dart';
import '../services/school_service.dart' show SchoolException;
import 'independent_timetable_project_screen.dart';

/// "Build Timetable for Another School" (added 2026-09-16) — entry point
/// from the Timetable hub. Lists every independent project this teacher
/// has created; each one is a from-scratch timetable for an institution
/// that has nothing to do with their own subscribed school (see
/// [IndependentTimetableService]'s doc comment for the full picture).
class IndependentTimetableListScreen extends StatefulWidget {
  const IndependentTimetableListScreen({super.key});

  @override
  State<IndependentTimetableListScreen> createState() => _IndependentTimetableListScreenState();
}

class _IndependentTimetableListScreenState extends State<IndependentTimetableListScreen> {
  final _service = IndependentTimetableService();
  bool _creating = false;

  Future<void> _createProject() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New timetable project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Institution name', hintText: 'e.g. Kasama Secondary School', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _creating = true);
    try {
      final project = await _service.createProject(name);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => IndependentTimetableProjectScreen(project: project)));
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _deleteProject(IndependentTimetableProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this project?'),
        content: Text('"${project.institutionName}" and everything built for it (classes, setup, generated timetable) will be permanently deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.deleteProject(project.id);
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Build Timetable for Another School')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _creating ? null : _createProject,
        icon: _creating ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: StreamBuilder<List<IndependentTimetableProject>>(
        stream: _service.watchMyProjects(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final projects = snapshot.data!;
          if (projects.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  "Build a complete, from-scratch timetable for any other institution — fully separate from your own "
                  "subscribed school, using the same setup and generator. Tap \"New project\" to start.",
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            itemCount: projects.length,
            itemBuilder: (context, index) {
              final project = projects[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.apartment_outlined),
                  title: Text(project.institutionName),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: () => _deleteProject(project)),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => IndependentTimetableProjectScreen(project: project))),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
