import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_service.dart';
import 'school_logo_card.dart';

/// Stage 3 of School Network — the member roster + role assignment. Real
/// permission enforcement happens server-side in `updateSchoolMemberRole`
/// (index.ts); this screen's own role gating is a UX convenience, not the
/// security boundary.
///
/// Class-specific Grade Teacher assignment is interim here: this app has
/// no stable cross-device "class" identity yet (Report Form Pipeline
/// classes are local SQLite auto-increment rows, not shared records) — see
/// the School Network Stage 4-7 build note. Until that bridge exists,
/// "classes" for a Grade Teacher assignment are free-text labels the
/// school agrees on by name (e.g. "Grade 8A"), not linked to any specific
/// device's Report Form Pipeline data.
class SchoolRosterScreen extends StatefulWidget {
  const SchoolRosterScreen({required this.school, super.key});
  final School school;

  @override
  State<SchoolRosterScreen> createState() => _SchoolRosterScreenState();
}

class _SchoolRosterScreenState extends State<SchoolRosterScreen> {
  final _schoolService = SchoolService();
  SchoolRole? _myRole;

  @override
  void initState() {
    super.initState();
    _loadMyRole();
  }

  Future<void> _loadMyRole() async {
    final claim = await _schoolService.currentSchoolClaim();
    if (mounted) setState(() => _myRole = claim.role);
  }

  bool get _canManageOperators =>
      _myRole?.isLeadership == true || _myRole == SchoolRole.administrator;

  /// Timetable Generation, Stage 9 — co-opting/revoking a Timetable
  /// Operator. Kept separate from [_assignRole] since it's an additive
  /// grant, not a role change — a teacher keeps their normal role and
  /// simply also gets timetable-management rights.
  Future<void> _toggleTimetableOperator(SchoolMember member) async {
    try {
      await _schoolService.setTimetableOperator(
          schoolId: widget.school.id,
          targetUid: member.uid,
          isOperator: !member.timetableOperator);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '${member.name} is ${member.timetableOperator ? 'no longer' : 'now'} a Timetable Operator.')),
      );
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _assignRole(SchoolMember member) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    final canAssignLeadership = _myRole?.isLeadership ?? false;
    final canHandoffGradeTeacher = _myRole == SchoolRole.gradeTeacher;
    if (!canAssignLeadership && !canHandoffGradeTeacher) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Only the Head Teacher or Deputy can change roles here.')),
      );
      return;
    }

    final result =
        await showDialog<({SchoolRole role, List<String>? classIds})>(
      context: context,
      builder: (dialogContext) => _RoleAssignDialog(
          member: member, allowLeadershipRoles: canAssignLeadership),
    );
    if (result == null) return;

    try {
      await _schoolService.updateMemberRole(
        schoolId: widget.school.id,
        targetUid: member.uid,
        role: result.role,
        classIds: result.classIds,
      );
      if (result.role != SchoolRole.gradeTeacher && myUid == member.uid) {
        // Own role just changed (rare from this screen, but keep the local
        // claim cache correct if it happens).
        await _schoolService.currentSchoolClaim(forceRefresh: true);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${member.name} is now ${result.role.label}.')));
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.school.name} — Staff')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: SchoolLogoCard(
                schoolId: widget.school.id,
                canManage: (_myRole?.isLeadership ?? false) ||
                    _myRole == SchoolRole.administrator),
          ),
          Expanded(
            child: StreamBuilder<List<SchoolMember>>(
              stream: _schoolService.watchMembers(widget.school.id),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final members = snapshot.data!;
                if (members.isEmpty) {
                  return const Center(child: Text('No staff members yet.'));
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: members.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (context, index) {
                    final member = members[index];
                    return ListTile(
                      leading: CircleAvatar(
                          child: Text(member.name.isNotEmpty
                              ? member.name[0].toUpperCase()
                              : '?')),
                      title: Text(member.name),
                      subtitle: Text(
                        [
                          member.role == SchoolRole.gradeTeacher &&
                                  member.classIds.isNotEmpty
                              ? '${member.role.label} — ${member.classIds.join(', ')}'
                              : member.role.label,
                          if (member.timetableOperator) 'Timetable Operator',
                        ].join(' · '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_canManageOperators)
                            IconButton(
                              icon: Icon(member.timetableOperator
                                  ? Icons.event_available
                                  : Icons.event_available_outlined),
                              tooltip: member.timetableOperator
                                  ? 'Revoke Timetable Operator'
                                  : 'Make Timetable Operator',
                              color: member.timetableOperator
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                              onPressed: () => _toggleTimetableOperator(member),
                            ),
                          if ((_myRole?.isLeadership ?? false) ||
                              _myRole == SchoolRole.gradeTeacher)
                            IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _assignRole(member)),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleAssignDialog extends StatefulWidget {
  const _RoleAssignDialog(
      {required this.member, required this.allowLeadershipRoles});
  final SchoolMember member;
  final bool allowLeadershipRoles;

  @override
  State<_RoleAssignDialog> createState() => _RoleAssignDialogState();
}

class _RoleAssignDialogState extends State<_RoleAssignDialog> {
  late SchoolRole _selected = widget.member.role;
  final _classesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _classesController.text = widget.member.classIds.join(', ');
  }

  @override
  void dispose() {
    _classesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final assignableRoles = widget.allowLeadershipRoles
        ? SchoolRole.values
        : const [
            SchoolRole.gradeTeacher
          ]; // a Grade Teacher can only hand off Grade Teacher for their own class

    return AlertDialog(
      title: Text('Set role for ${widget.member.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<SchoolRole>(
            initialValue: assignableRoles.contains(_selected)
                ? _selected
                : assignableRoles.first,
            items: assignableRoles
                .map((r) => DropdownMenuItem(value: r, child: Text(r.label)))
                .toList(),
            onChanged: (value) =>
                setState(() => _selected = value ?? _selected),
          ),
          if (_selected == SchoolRole.gradeTeacher) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _classesController,
              decoration: const InputDecoration(
                labelText: 'Classes (comma-separated)',
                hintText: 'e.g. Grade 8A, Grade 8B',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final classIds = _selected == SchoolRole.gradeTeacher
                ? _classesController.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList()
                : null;
            Navigator.of(context).pop((role: _selected, classIds: classIds));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
