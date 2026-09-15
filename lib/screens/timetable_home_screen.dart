import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_service.dart';
import '../services/teacher_auth_service.dart';
import 'generated_timetable_screen.dart';
import 'join_school_screen.dart';
import 'login_screen.dart';
import 'my_timetable_screen.dart';
import 'register_school_screen.dart';
import 'timetable_by_teacher_screen.dart';
import 'timetable_constraints_screen.dart';
import 'timetable_setup_screen.dart';

/// Timetable's own Home-screen entry point (added 2026-09-14, per direct
/// feedback while testing the APK build — "i can't see the time table
/// home button on the app, its supposed to be there, only control to
/// whom its access is given"). Previously Timetable was reachable only
/// via Home → Data Manager → My School → a tile, three taps deep and easy
/// to miss; this puts it on the main Home screen like every other major
/// function, with what it actually shows gated by the signed-in user's
/// real permission (leadership/Timetable Operator vs. everyone else, and
/// the school's subscription tier) rather than by hiding the entry point
/// itself.
class TimetableHomeScreen extends StatefulWidget {
  const TimetableHomeScreen({super.key});

  @override
  State<TimetableHomeScreen> createState() => _TimetableHomeScreenState();
}

class _TimetableHomeScreenState extends State<TimetableHomeScreen> {
  final _schoolService = SchoolService();
  bool _loading = true;
  School? _school;
  SchoolRole? _myRole;
  bool _isTimetableOperator = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final user = FirebaseAuth.instance.currentUser;
    final method = loginMethodOf(user);
    School? school;
    SchoolRole? role;
    var isOperator = false;
    if (method != TeacherLoginMethod.anonymous) {
      final claim = await _schoolService.currentSchoolClaim();
      role = claim.role;
      if (claim.schoolId != null) {
        school = await _schoolService.getSchool(claim.schoolId!);
        if (user != null) {
          final me = await _schoolService.getMember(claim.schoolId!, user.uid);
          isOperator = me?.timetableOperator ?? false;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _school = school;
      _myRole = role;
      _isTimetableOperator = isOperator;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final method = loginMethodOf(user);

    return Scaffold(
      appBar: AppBar(title: const Text('Timetable')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : method == TeacherLoginMethod.anonymous
              ? _buildSignUpPrompt(context)
              : _school == null
                  ? _buildNoSchool(context)
                  : _buildHub(context, _school!),
    );
  }

  Widget _buildSignUpPrompt(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.calendar_view_week_outlined, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Timetable is part of School Network — create an account first, then join or register your school.',
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

  Widget _buildHub(BuildContext context, School school) {
    final canManage = canManageTimetable(_myRole, _isTimetableOperator);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: const Icon(Icons.calendar_view_week_outlined),
          title: const Text('My Timetable'),
          subtitle: const Text('Your own periods for the week'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MyTimetableScreen(school: school))),
        ),
        ListTile(
          leading: const Icon(Icons.person_search_outlined),
          title: const Text('By Teacher'),
          subtitle: const Text("Browse any colleague's schedule"),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TimetableByTeacherScreen(school: school))),
        ),
        if (canManage) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text('Leadership / Timetable Operator', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
          ),
          if (school.hasTimetableAccess) ...[
            ListTile(
              leading: const Icon(Icons.tune_outlined),
              title: const Text('Timetable Setup'),
              subtitle: const Text('Day structure, subjects, teacher constraints'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TimetableSetupScreen(school: school))),
            ),
            ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: const Text('Timetable Constraints'),
              subtitle: const Text('Type teacher availability in plain language'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TimetableConstraintsScreen(school: school))),
            ),
            ListTile(
              leading: const Icon(Icons.grid_view_outlined),
              title: const Text('Generated Timetable'),
              subtitle: const Text('View, export, pin, or share — moving lessons is web-only'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GeneratedTimetableScreen(school: school))),
            ),
          ] else
            const ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Timetable Setup & Generation'),
              subtitle: Text('Needs a Gold subscription or higher for this school'),
              enabled: false,
            ),
        ],
      ],
    );
  }
}
