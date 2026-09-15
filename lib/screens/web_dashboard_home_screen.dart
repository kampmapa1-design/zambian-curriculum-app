import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_service.dart';
import '../services/teacher_auth_service.dart';
import 'broadcast_screen.dart';
import 'generated_timetable_screen.dart';
import 'join_school_screen.dart';
import 'leadership_dashboard_screen.dart';
import 'register_school_screen.dart';
import 'report_form_status_screen.dart';
import 'school_roster_screen.dart';
import 'staffroom_screen.dart';
import 'timetable_by_teacher_screen.dart';
import 'timetable_constraints_screen.dart';
import 'timetable_setup_screen.dart';

/// The web dashboard's real home (added 2026-09-14, per explicit
/// feedback after the first Stage 1 test — "it needs more icons of the
/// functions of the app including a side list of all the classes at the
/// school... the name of the grade teacher must appear alongside their
/// class"). A persistent left sidebar (Stage 7's "sidebar navigation,
/// desktop-appropriate layout" pulled forward, since the user reacted to
/// the shape of this screen directly) with the school-wide class board
/// (see [ClassProgressBoard]) as the default content — populates itself
/// live as Grade Teachers connect classes from their phones, no setup
/// needed on the web side.
class WebDashboardHomeScreen extends StatefulWidget {
  const WebDashboardHomeScreen({super.key});

  @override
  State<WebDashboardHomeScreen> createState() => _WebDashboardHomeScreenState();
}

enum _WebSection { dashboard, reportFormStatus, timetable, timetableConstraints, generatedTimetable, timetableByTeacher, staff, staffroom, broadcast }

class _WebDashboardHomeScreenState extends State<WebDashboardHomeScreen> {
  final _schoolService = SchoolService();
  bool _loading = true;
  School? _school;
  SchoolRole? _myRole;
  bool _isTimetableOperator = false;
  _WebSection _section = _WebSection.dashboard;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final claim = await _schoolService.currentSchoolClaim();
    School? school;
    var isTimetableOperator = false;
    if (claim.schoolId != null) {
      school = await _schoolService.getSchool(claim.schoolId!);
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        final me = await _schoolService.getMember(claim.schoolId!, uid);
        isTimetableOperator = me?.timetableOperator ?? false;
      }
    }
    if (!mounted) return;
    setState(() {
      _school = school;
      _myRole = claim.role;
      _isTimetableOperator = isTimetableOperator;
      _loading = false;
    });
  }

  bool get _isLeadership => _myRole?.isLeadership == true || _myRole == SchoolRole.administrator;
  bool get _canManageTimetable => canManageTimetable(_myRole, _isTimetableOperator);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final school = _school;
    if (school == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('My School')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("You're not part of a school yet.", textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton.icon(
                  icon: const Icon(Icons.add_business_outlined),
                  label: const Text('Register a school'),
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegisterSchoolScreen()));
                    if (mounted) _load();
                  },
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.group_add_outlined),
                  label: const Text('Join with a school code'),
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const JoinSchoolScreen()));
                    if (mounted) _load();
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            school: school,
            isLeadership: _isLeadership,
            canManageTimetable: _canManageTimetable,
            institutionalSubscription: school.institutionalSubscription,
            section: _section,
            onSelect: (s) => setState(() => _section = s),
            onSignedOut: () => _load(),
          ),
          Expanded(child: _buildContent(school)),
        ],
      ),
    );
  }

  Widget _buildContent(School school) {
    switch (_section) {
      case _WebSection.dashboard:
        return _isLeadership
            ? ClassProgressBoard(school: school)
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "You're signed in to ${school.name}. The school-wide class dashboard is only shown to Head "
                  'Teacher, Deputy, or an appointed Administrator — use the sidebar to reach Staff & Roles or the '
                  'Staffroom instead.',
                ),
              );
      case _WebSection.reportFormStatus:
        return ReportFormStatusScreen(school: school, canEditWindow: _myRole == SchoolRole.headTeacher || _myRole == SchoolRole.deputy);
      case _WebSection.timetable:
        return TimetableSetupScreen(school: school);
      case _WebSection.timetableConstraints:
        return TimetableConstraintsScreen(school: school);
      case _WebSection.generatedTimetable:
        return GeneratedTimetableScreen(school: school);
      case _WebSection.timetableByTeacher:
        return TimetableByTeacherScreen(school: school);
      case _WebSection.staff:
        return SchoolRosterScreen(school: school);
      case _WebSection.staffroom:
        return StaffroomScreen(school: school);
      case _WebSection.broadcast:
        return BroadcastScreen(school: school);
    }
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.school,
    required this.isLeadership,
    required this.canManageTimetable,
    required this.institutionalSubscription,
    required this.section,
    required this.onSelect,
    required this.onSignedOut,
  });

  final School school;
  final bool isLeadership;
  final bool canManageTimetable;
  final bool institutionalSubscription;
  final _WebSection section;
  final ValueChanged<_WebSection> onSelect;
  final VoidCallback onSignedOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Smart Teacher', style: Theme.of(context).textTheme.labelMedium),
                  Text(school.name, style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const Divider(height: 1),
            _navTile(context, icon: Icons.dashboard_outlined, label: 'Dashboard', value: _WebSection.dashboard),
            if (isLeadership)
              _navTile(context, icon: Icons.fact_check_outlined, label: 'Report Form Status', value: _WebSection.reportFormStatus),
            if (canManageTimetable && school.hasTimetableAccess) ...[
              _navTile(context, icon: Icons.calendar_view_week_outlined, label: 'Timetable Setup', value: _WebSection.timetable),
              _navTile(context, icon: Icons.chat_outlined, label: 'Timetable Constraints', value: _WebSection.timetableConstraints),
              _navTile(context, icon: Icons.grid_view_outlined, label: 'Generated Timetable', value: _WebSection.generatedTimetable),
            ] else if (canManageTimetable)
              const ListTile(
                leading: Icon(Icons.calendar_view_week_outlined),
                title: Text('Timetable'),
                subtitle: Text('Needs Gold subscription or higher', style: TextStyle(fontSize: 11)),
                enabled: false,
              ),
            _navTile(context, icon: Icons.person_search_outlined, label: 'Timetable — By Teacher', value: _WebSection.timetableByTeacher),
            _navTile(context, icon: Icons.groups_outlined, label: 'Staff & Roles', value: _WebSection.staff),
            _navTile(context, icon: Icons.forum_outlined, label: 'Staffroom', value: _WebSection.staffroom),
            if (isLeadership && institutionalSubscription)
              _navTile(context, icon: Icons.campaign_outlined, label: 'Broadcast to Guardians', value: _WebSection.broadcast),
            const Spacer(),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () async {
                await TeacherAuthService().signOut();
                onSignedOut();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _navTile(BuildContext context, {required IconData icon, required String label, required _WebSection value}) {
    final selected = section == value;
    return Material(
      color: selected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        selected: selected,
        onTap: () => onSelect(value),
      ),
    );
  }
}
