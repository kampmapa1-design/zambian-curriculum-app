import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_service.dart';
import 'teacher_timetable_screen.dart';

/// Timetable Generation, Stage 11 — "a list of all teachers at the
/// school, and tapping a teacher's name reveals their complete personal
/// teaching timetable." Reuses the same member roster School Network's
/// Staff & Roles already loads; this screen is purely a different way in
/// (by teacher, not by class).
class TimetableByTeacherScreen extends StatelessWidget {
  const TimetableByTeacherScreen({required this.school, super.key});
  final School school;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Timetable — By Teacher')),
      body: StreamBuilder<List<SchoolMember>>(
        stream: SchoolService().watchMembers(school.id),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final members = [...snapshot.data!]..sort((a, b) => a.name.compareTo(b.name));
          if (members.isEmpty) return const Center(child: Text('No staff members yet.'));
          return ListView.separated(
            itemCount: members.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final member = members[index];
              return ListTile(
                leading: CircleAvatar(child: Text(member.name.isNotEmpty ? member.name[0].toUpperCase() : '?')),
                title: Text(member.name),
                subtitle: Text(member.role.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => TeacherTimetableScreen(school: school, teacherUid: member.uid, teacherName: member.name)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
