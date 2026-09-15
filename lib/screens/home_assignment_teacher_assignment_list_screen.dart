import 'package:flutter/material.dart';

import '../models/home_assignment.dart';
import '../models/school.dart';
import '../services/home_assignment_service.dart';
import 'home_assignment_queue_screen.dart';

/// Home Assignment epic, Stages 8-12 — every Home Assignment issued to
/// one class, with a "Remind" action (Stage 12) alongside each.
class HomeAssignmentTeacherAssignmentListScreen extends StatefulWidget {
  const HomeAssignmentTeacherAssignmentListScreen({required this.school, required this.schoolClass, super.key});
  final School school;
  final SchoolClass schoolClass;

  @override
  State<HomeAssignmentTeacherAssignmentListScreen> createState() => _HomeAssignmentTeacherAssignmentListScreenState();
}

class _HomeAssignmentTeacherAssignmentListScreenState extends State<HomeAssignmentTeacherAssignmentListScreen> {
  final _service = HomeAssignmentService();
  bool _reminding = false;

  Future<void> _remind(IssuedHomeAssignment a) async {
    setState(() => _reminding = true);
    try {
      final result = await _service.remindNonSubmitters(schoolId: widget.school.id, classId: widget.schoolClass.id, assignmentId: a.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reminded ${result.remindedCount} learner(s) — ${result.emailsSent} email(s) sent, ${result.whatsappRecipients.length} WhatsApp contact(s) to tap through.')),
      );
    } on HomeAssignmentException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _reminding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.schoolClass.classGrade)),
      body: StreamBuilder<List<IssuedHomeAssignment>>(
        stream: _service.watchAssignments(widget.school.id, widget.schoolClass.id),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final assignments = snapshot.data!;
          if (assignments.isEmpty) {
            return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No home assignments issued to this class yet.')));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: assignments.length,
            itemBuilder: (context, index) {
              final a = assignments[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.home_work_outlined),
                  title: Text(a.title),
                  subtitle: Text('${a.subjectName} · ${a.questions.length} question${a.questions.length == 1 ? '' : 's'}${a.deadline != null ? ' · due ${a.deadline!.day}/${a.deadline!.month}/${a.deadline!.year}' : ''}'),
                  trailing: _reminding
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4))
                      : PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'remind') _remind(a);
                          },
                          itemBuilder: (_) => [const PopupMenuItem(value: 'remind', child: Text('Remind non-submitters'))],
                        ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => HomeAssignmentQueueScreen(school: widget.school, schoolClass: widget.schoolClass, assignment: a)),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
