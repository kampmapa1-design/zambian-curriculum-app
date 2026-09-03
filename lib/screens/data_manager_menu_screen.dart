import 'package:flutter/material.dart';

import '../widgets/function_button.dart';
import 'grade_teacher_home_screen.dart';

/// "Data Manager" — a home-screen entry point for administrative/record-
/// keeping functions, starting with Grade Teacher (class roster, Broad
/// Mark Sheet, report forms). Named and structured (2026-09-03, per
/// explicit request) to hold more than one such function over time,
/// following the same "one home-screen button leading to a sub-menu of
/// real, separate functions" pattern already used for Teaching Resources
/// and Assignments/Tests — Grade Teacher is the first entry here, not the
/// only one this screen is meant for.
class DataManagerMenuScreen extends StatelessWidget {
  const DataManagerMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data Manager')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FunctionButton(
            icon: Icons.groups_outlined,
            label: 'Grade Teacher',
            subtitle: 'Class roster, Broad Mark Sheet, and report forms',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const GradeTeacherHomeScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
