import 'package:flutter/material.dart';

import '../widgets/function_button.dart';
import 'assignment_submission_screen.dart';
import 'teacher_submissions_dashboard_screen.dart';
import 'test_submission_screen.dart';

/// Groups Assignment Submission, Test Submission, and (2026-09-02) the
/// teacher-side Submissions Dashboard behind one home-screen entry point.
/// The first two keep their exact prior functions; the Dashboard is the
/// receiving end of the same two features — natural to live alongside
/// them rather than adding a third loose home-screen button.
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
          FunctionButton(
            icon: Icons.inbox_outlined,
            label: 'Submissions Dashboard (For Teachers)',
            subtitle: 'Review assignments and tests your students have sent you',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TeacherSubmissionsDashboardScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
