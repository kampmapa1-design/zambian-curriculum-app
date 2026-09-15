import 'package:flutter/material.dart';

import '../widgets/function_button.dart';
import 'account_settings_screen.dart';
import 'assignment_submission_screen.dart';
import 'home_assignment_pupil_screen.dart';
import 'join_class_pupil_screen.dart';
import 'test_submission_screen.dart';

/// Home Assignment epic, Stage 2 (added 2026-09-14) — the distinct home
/// screen a Pupil-role account sees instead of [HomeScreen]. Per the
/// brief: "Hide teacher-only tools... from this view entirely, rather
/// than just disabling them" — so this is its own screen with its own
/// short tile list, not [HomeScreen] with things greyed out. Every tile
/// here is a real, already-working screen (Assignment/Test Submission)
/// except Home Assignment, which is a real screen too but depends on
/// later stages of this same epic (receiving/submitting a teacher-issued
/// Home Assignment) to have anything to show.
class PupilHomeScreen extends StatelessWidget {
  const PupilHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Teacher'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountSettingsScreen())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FunctionButton(
            icon: Icons.assignment_turned_in_outlined,
            label: 'Assignment Submission',
            subtitle: 'Photograph a handwritten assignment and send it to your teacher, with proof of submission',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AssignmentSubmissionScreen()),
            ),
          ),
          FunctionButton(
            icon: Icons.quiz_outlined,
            label: 'Test Submission',
            subtitle: 'Photograph a handwritten test and send it to your teacher/lecturer, with proof of submission',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TestSubmissionScreen()),
            ),
          ),
          FunctionButton(
            icon: Icons.home_work_outlined,
            label: 'Home Assignment',
            subtitle: "Assignments your subject teachers have sent you",
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HomeAssignmentPupilScreen()),
            ),
          ),
          FunctionButton(
            icon: Icons.group_add_outlined,
            label: 'Join a Class',
            subtitle: 'Link your account to your school and class, so assignments reach you here',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const JoinClassPupilScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
