import 'package:flutter/material.dart';

import '../widgets/function_button.dart';
import 'assignment_submission_screen.dart';
import 'test_submission_screen.dart';

/// Groups Assignment Submission and Test Submission behind one home-screen
/// entry point (added 2026-09-02, replacing two separate home-screen
/// buttons). Both keep their exact prior functions — this screen only
/// changes where they're reached from, not what they do.
class AssignmentsTestsMenuScreen extends StatelessWidget {
  const AssignmentsTestsMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assignments, Exams & Test Submissions')),
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
            subtitle: 'Photograph a handwritten test and send it to your teacher, with proof of submission',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TestSubmissionScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
