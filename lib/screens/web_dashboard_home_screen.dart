import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/school.dart';
import '../models/web_dashboard_access.dart';
import '../services/personal_subscription_service.dart';
import '../services/school_service.dart';
import '../services/teacher_auth_service.dart';
import 'broadcast_screen.dart';
import 'generated_timetable_screen.dart';
import 'join_school_screen.dart';
import 'leadership_dashboard_screen.dart';
import 'owner_finance_screen.dart';
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

class _WebDashboardHomeScreenState extends State<WebDashboardHomeScreen> {
  final _schoolService = SchoolService();
  final _personalSubscriptionService = PersonalSubscriptionService();
  bool _loading = true;
  School? _school;
  SchoolRole? _myRole;
  bool _isTimetableOperator = false;
  SubscriptionTier _personalTier = SubscriptionTier.basic;

  bool _hasTimetableAccess(School school) => School.meetsTimetableTier(school: school, personalTier: _personalTier);
  // The app OWNER (listed in the server-side ownerData/settings) gets the Owner
  // finance section here. Asked of the server, never decided by this screen.
  bool _isOwner = false;
  WebDashboardSection? _section;

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
    var isOwner = false;
    try {
      final result = await FirebaseFunctions.instance.httpsCallable('amIOwner').call<Object?>();
      final data = result.data;
      isOwner = data is Map && data['isOwner'] == true;
    } catch (_) {
      // Not the owner, offline, or the function isn't deployed yet - no owner section.
    }
    final personalTier = await _personalSubscriptionService.fetchTier();
    if (!mounted) return;
    setState(() {
      _school = school;
      _myRole = claim.role;
      _isTimetableOperator = isTimetableOperator;
      _isOwner = isOwner;
      _personalTier = personalTier;
      _section = null; // re-pick the default section for whoever just signed in
      _loading = false;
    });
  }

  WebDashboardAccess _accessFor(School school) => webDashboardAccess(
        role: _myRole,
        isTimetableOperator: _isTimetableOperator,
        institutionalSchool: schoolIsInstitutional(school),
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final school = _school;

    if (school == null) {
      if (_isOwner) {
        // The owner doesn't need a school to use the owner tools.
        return Scaffold(
          body: Row(
            children: [
              _Sidebar(
                schoolName: null,
                sections: const [WebDashboardSection.ownerFinance],
                showTimetableNotice: false,
                selected: WebDashboardSection.ownerFinance,
                onSelect: (_) {},
                onSignedOut: _load,
              ),
              const Expanded(child: OwnerFinanceScreen(embedded: true)),
            ],
          ),
        );
      }
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
                const SizedBox(height: 24),
                const _AccountIdTile(),
              ],
            ),
          ),
        ),
      );
    }

    final access = _accessFor(school);
    final hasTimetableAccess = _hasTimetableAccess(school);
    final sections = webDashboardSections(
      access: access,
      role: _myRole,
      institutionalSchool: schoolIsInstitutional(school),
      hasTimetableAccess: hasTimetableAccess,
      isOwner: _isOwner,
    );
    final showNotice = showTimetableUpgradeNotice(access: access, hasTimetableAccess: hasTimetableAccess);

    // Nothing to offer this person: not an administrator, not the timetable
    // operator, not the owner. Say so plainly rather than show an empty shell.
    if (sections.isEmpty && !showNotice) {
      return _NoAccessView(schoolName: school.name, onSignedOut: _load);
    }

    final selected = (_section != null && sections.contains(_section)) ? _section : (sections.isNotEmpty ? sections.first : null);
    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            schoolName: school.name,
            sections: sections,
            showTimetableNotice: showNotice,
            selected: selected,
            onSelect: (s) => setState(() => _section = s),
            onSignedOut: _load,
          ),
          Expanded(child: selected == null ? const _TimetableUpgradeNotice() : _buildContent(school, selected)),
        ],
      ),
    );
  }

  Widget _buildContent(School school, WebDashboardSection section) {
    switch (section) {
      case WebDashboardSection.dashboard:
        return ClassProgressBoard(school: school);
      case WebDashboardSection.reportFormStatus:
        return ReportFormStatusScreen(school: school, canEditWindow: _myRole == SchoolRole.headTeacher || _myRole == SchoolRole.deputy);
      case WebDashboardSection.timetable:
        return TimetableSetupScreen(school: school);
      case WebDashboardSection.timetableConstraints:
        return TimetableConstraintsScreen(school: school);
      case WebDashboardSection.generatedTimetable:
        return GeneratedTimetableScreen(school: school);
      case WebDashboardSection.timetableByTeacher:
        return TimetableByTeacherScreen(school: school);
      case WebDashboardSection.staff:
        return SchoolRosterScreen(school: school);
      case WebDashboardSection.staffroom:
        return StaffroomScreen(school: school);
      case WebDashboardSection.broadcast:
        return BroadcastScreen(school: school);
      case WebDashboardSection.ownerFinance:
        // Defence in depth only: the server refuses anyone who isn't the owner.
        return _isOwner ? const OwnerFinanceScreen(embedded: true) : const SizedBox.shrink();
    }
  }
}

/// Signed in to a school, but not an administrator, the timetable operator or the owner.
class _NoAccessView extends StatelessWidget {
  const _NoAccessView({required this.schoolName, required this.onSignedOut});

  final String schoolName;
  final VoidCallback onSignedOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(schoolName)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 40),
                const SizedBox(height: 16),
                Text(
                  'The web dashboard is for school administrators',
                  key: const Key('no-access-title'),
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'It is available to the Head Teacher, the Deputy, an appointed Administrator, and the school\'s '
                  'timetable operator. Everything else is in the Smart Teacher app on your phone.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  icon: const Icon(Icons.logout_outlined),
                  label: const Text('Sign out'),
                  onPressed: () async {
                    await TeacherAuthService().signOut();
                    onSignedOut();
                  },
                ),
                const SizedBox(height: 16),
                const _AccountIdTile(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An administrator (or the operator) whose school's plan doesn't include timetable creation.
class _TimetableUpgradeNotice extends StatelessWidget {
  const _TimetableUpgradeNotice();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.calendar_view_week_outlined, size: 40),
              const SizedBox(height: 16),
              Text('Timetable creation needs a Gold subscription or higher',
                  key: const Key('timetable-upgrade-title'), style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const Text(
                'On the web dashboard, schools without the Institutional subscription can use timetable creation only, '
                'and your school\'s current plan doesn\'t include it yet.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.schoolName,
    required this.sections,
    required this.showTimetableNotice,
    required this.selected,
    required this.onSelect,
    required this.onSignedOut,
  });

  /// Null for an owner who isn't part of any school.
  final String? schoolName;
  final List<WebDashboardSection> sections;
  final bool showTimetableNotice;
  final WebDashboardSection? selected;
  final ValueChanged<WebDashboardSection> onSelect;
  final VoidCallback onSignedOut;

  static (IconData, String) _look(WebDashboardSection s) => switch (s) {
        WebDashboardSection.dashboard => (Icons.dashboard_outlined, 'Dashboard'),
        WebDashboardSection.reportFormStatus => (Icons.fact_check_outlined, 'Report Form Status'),
        WebDashboardSection.timetable => (Icons.calendar_view_week_outlined, 'Timetable Setup'),
        WebDashboardSection.timetableConstraints => (Icons.chat_outlined, 'Timetable Constraints'),
        WebDashboardSection.generatedTimetable => (Icons.grid_view_outlined, 'Generated Timetable'),
        WebDashboardSection.timetableByTeacher => (Icons.person_search_outlined, 'Timetable — By Teacher'),
        WebDashboardSection.staff => (Icons.groups_outlined, 'Staff & Roles'),
        WebDashboardSection.staffroom => (Icons.forum_outlined, 'Staffroom'),
        WebDashboardSection.broadcast => (Icons.campaign_outlined, 'Broadcast to Guardians'),
        WebDashboardSection.ownerFinance => (Icons.insights_outlined, 'Owner finance'),
      };

  @override
  Widget build(BuildContext context) {
    final schoolSections = sections.where((s) => s != WebDashboardSection.ownerFinance);
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
                  Text(schoolName ?? 'Owner', style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const Divider(height: 1),
            for (final s in schoolSections) _navTile(context, s),
            if (showTimetableNotice)
              const ListTile(
                leading: Icon(Icons.calendar_view_week_outlined),
                title: Text('Timetable'),
                subtitle: Text('Needs Gold subscription or higher', style: TextStyle(fontSize: 11)),
                enabled: false,
              ),
            if (sections.contains(WebDashboardSection.ownerFinance)) ...[
              if (schoolSections.isNotEmpty || showTimetableNotice) const Divider(height: 1),
              _navTile(context, WebDashboardSection.ownerFinance),
            ],
            const Spacer(),
            const _AccountIdTile(),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout_outlined),
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

  Widget _navTile(BuildContext context, WebDashboardSection value) {
    final (icon, label) = _look(value);
    final isSelected = selected == value;
    return Material(
      color: isSelected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        selected: isSelected,
        onTap: () => onSelect(value),
      ),
    );
  }
}

/// The signed-in Firebase user id, tap to copy - what the app owner pastes into
/// `ownerUids` in the owner-only settings to unlock the Owner finance section
/// (see docs/MONETIZATION_SETUP.md). Harmless to show: it is not a secret.
class _AccountIdTile extends StatelessWidget {
  const _AccountIdTile();

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      title: Text('Account ID (tap to copy)', style: Theme.of(context).textTheme.bodySmall),
      subtitle: Text(uid, key: const Key('web-account-id'), style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: uid));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account ID copied')));
      },
    );
  }
}
