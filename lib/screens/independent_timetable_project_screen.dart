import 'package:flutter/material.dart';

import '../models/independent_timetable_project.dart';
import 'independent_timetable_classes_screen.dart';
import 'independent_timetable_constraints_screen.dart';
import 'independent_timetable_generated_screen.dart';
import 'independent_timetable_setup_screen.dart';

/// "Build Timetable for Another School" (added 2026-09-16) — one
/// independent project's own hub, mirroring [TimetableHomeScreen]'s
/// leadership section but with no role/subscription gating at all:
/// whoever created this project is the only person who can ever see it
/// (enforced server-side, see [IndependentTimetableService]).
class IndependentTimetableProjectScreen extends StatelessWidget {
  const IndependentTimetableProjectScreen({required this.project, super.key});
  final IndependentTimetableProject project;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(project.institutionName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: const Text('Classes & Subjects'),
            subtitle: const Text('Add classes, their subjects, and who teaches each one'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => IndependentTimetableClassesScreen(project: project))),
          ),
          ListTile(
            leading: const Icon(Icons.tune_outlined),
            title: const Text('Timetable Setup'),
            subtitle: const Text('Day structure, subject periods/week, practical subjects'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => IndependentTimetableSetupScreen(project: project))),
          ),
          ListTile(
            leading: const Icon(Icons.chat_outlined),
            title: const Text('Timetable Constraints'),
            subtitle: const Text('Type teacher availability in plain language'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => IndependentTimetableConstraintsScreen(project: project))),
          ),
          ListTile(
            leading: const Icon(Icons.grid_view_outlined),
            title: const Text('Generated Timetable'),
            subtitle: const Text('View, export, or share once generated'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => IndependentTimetableGeneratedScreen(project: project))),
          ),
        ],
      ),
    );
  }
}
