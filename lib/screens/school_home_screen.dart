import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_service.dart';
import '../services/teacher_auth_service.dart';
import 'join_school_screen.dart';
import 'leadership_dashboard_screen.dart';
import 'login_screen.dart';
import 'my_timetable_screen.dart';
import 'register_school_screen.dart';
import 'school_roster_screen.dart';
import 'staffroom_screen.dart';
import 'timetable_by_teacher_screen.dart';

/// "My School" — entry point for School Network (added 2026-09-13). Shown
/// from Data Manager. A still-anonymous teacher is asked to sign up first
/// (real phone/email) — school membership is tied to a permanent identity,
/// since an anonymous session can be lost on reinstall and losing your
/// school membership with it would be a real, avoidable problem. A teacher
/// with a real account but no school yet sees Register/Join; a teacher
/// already in a school sees its details and a link to the staff roster.
class SchoolHomeScreen extends StatefulWidget {
  const SchoolHomeScreen({super.key});

  @override
  State<SchoolHomeScreen> createState() => _SchoolHomeScreenState();
}

class _SchoolHomeScreenState extends State<SchoolHomeScreen> {
  final _schoolService = SchoolService();
  bool _loading = true;
  School? _school;
  SchoolRole? _myRole;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final user = FirebaseAuth.instance.currentUser;
    School? school;
    SchoolRole? role;
    if (user != null && !user.isAnonymous) {
      final claim = await _schoolService.currentSchoolClaim();
      role = claim.role;
      if (claim.schoolId != null) school = await _schoolService.getSchool(claim.schoolId!);
    }
    if (!mounted) return;
    setState(() {
      _school = school;
      _myRole = role;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final method = loginMethodOf(user);

    return Scaffold(
      appBar: AppBar(title: const Text('My School')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : method == TeacherLoginMethod.anonymous
              ? _buildSignUpPrompt(context)
              : _school == null
                  ? _buildNoSchool(context)
                  : _buildSchool(context, _school!),
    );
  }

  Widget _buildSignUpPrompt(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_outline, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Create an account first — school membership is tied to your identity, so it survives even if you reinstall the app.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
                  if (mounted) _load();
                },
                child: const Text('Sign up / Sign in'),
              ),
            ],
          ),
        ),
      );

  Widget _buildNoSchool(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.apartment_outlined, size: 56),
              const SizedBox(height: 16),
              const Text("You're not part of a school yet.", textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: const Icon(Icons.add_business_outlined),
                label: const Text('Register a school'),
                onPressed: () async {
                  final school = await Navigator.of(context).push<School>(
                    MaterialPageRoute(builder: (_) => const RegisterSchoolScreen()),
                  );
                  if (school != null && mounted) setState(() => _school = school);
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('Join with a school code'),
                onPressed: () async {
                  final school = await Navigator.of(context).push<School>(
                    MaterialPageRoute(builder: (_) => const JoinSchoolScreen()),
                  );
                  if (school != null && mounted) setState(() => _school = school);
                },
              ),
            ],
          ),
        ),
      );

  Widget _buildSchool(BuildContext context, School school) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(school.name, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text('${school.district}, ${school.province} Province'),
                  const SizedBox(height: 4),
                  Text('Head Teacher: ${school.headTeacherName}'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('School code: '),
                      Text(school.code, style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: const Text('Staff & roles'),
            subtitle: const Text('View colleagues and assign roles'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SchoolRosterScreen(school: school)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: const Text('Staffroom'),
            subtitle: const Text('Open messages for the whole school'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => StaffroomScreen(school: school)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.calendar_view_week_outlined),
            title: const Text('My Timetable'),
            subtitle: const Text('Your own periods for the week'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => MyTimetableScreen(school: school)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person_search_outlined),
            title: const Text('Timetable — By Teacher'),
            subtitle: const Text("Browse any colleague's schedule"),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => TimetableByTeacherScreen(school: school)),
            ),
          ),
          if (_myRole?.isLeadership == true || _myRole == SchoolRole.administrator)
            ListTile(
              leading: const Icon(Icons.dashboard_outlined),
              title: const Text('Leadership Dashboard'),
              subtitle: const Text('Report-form progress across every class'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => LeadershipDashboardScreen(school: school)),
              ),
            ),
        ],
      );
}
