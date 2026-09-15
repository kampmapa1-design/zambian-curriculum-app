import 'package:flutter/material.dart';

import '../widgets/function_button.dart';
import 'account_settings_screen.dart';
import 'grade_teacher_home_screen.dart';
import 'notifications_screen.dart';
import 'school_home_screen.dart';
import 'subject_teacher_screen.dart';

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
          FunctionButton(
            icon: Icons.account_circle_outlined,
            label: 'My Account',
            subtitle: 'Sign up with phone or email, or manage an existing account',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AccountSettingsScreen()),
            ),
          ),
          FunctionButton(
            icon: Icons.apartment_outlined,
            label: 'My School',
            subtitle: 'Register or join your school, view staff and roles',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SchoolHomeScreen()),
            ),
          ),
          FunctionButton(
            icon: Icons.edit_note_outlined,
            label: 'Subject Teacher',
            subtitle: 'Update report form scores for classes assigned to you',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SubjectTeacherScreen()),
            ),
          ),
          FunctionButton(
            icon: Icons.notifications_none,
            label: 'Notifications',
            subtitle: "See when someone edits an entry you submitted",
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
