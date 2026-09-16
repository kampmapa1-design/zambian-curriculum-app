import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/home_assignment.dart';
import '../models/school.dart';
import '../services/home_assignment_service.dart';
import 'home_assignment_queue_screen.dart';

/// Home Assignment epic, Stages 8-12 — every Home Assignment issued to
/// one class, with a "Remind" action (Stage 12) alongside each.
///
/// "Build the WhatsApp reminder for parents who have not yet replied"
/// (2026-09-16, per explicit request): `remindHomeAssignmentNonSubmitters`
/// already computed and returned `whatsappRecipients`, but this screen
/// only ever reported their COUNT in a SnackBar — the same "server can't
/// open WhatsApp for anyone but the device's own user" constraint every
/// other broadcast in this app already respects meant nothing was
/// actually tappable. [_showWhatsAppReminders] is the real fix: a
/// tappable list, same shape as HomeAssignmentSendScreen's own
/// post-send WhatsApp list.
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
      if (result.remindedCount == 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Everyone has already submitted — no reminders needed.')));
        return;
      }
      await _showWhatsAppReminders(a, result.emailsSent, result.whatsappRecipients);
    } on HomeAssignmentException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _reminding = false);
    }
  }

  Future<void> _openWhatsAppReminder(IssuedHomeAssignment a, String name, String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '').replaceAll('+', '');
    final code = a.referenceCode;
    final message = 'Reminder: "${a.title}" (${a.subjectName}) has not been submitted yet for $name.'
        '${a.deadline != null ? ' It is due ${a.deadline!.day}/${a.deadline!.month}/${a.deadline!.year}.' : ''}'
        '${code != null ? '\n\nReference code: $code\nPlease keep this reference code in the reply.' : ''}';
    final uri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(message)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _showWhatsAppReminders(IssuedHomeAssignment a, int emailsSent, List<({String name, String phone})> whatsappRecipients) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.all(16),
          children: [
            Text('Reminders for "${a.title}"', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('$emailsSent email reminder(s) sent to guardians.', style: const TextStyle(fontSize: 13)),
            if (whatsappRecipients.isEmpty)
              const Padding(padding: EdgeInsets.only(top: 12), child: Text('No WhatsApp numbers on file for the remaining non-submitters.'))
            else ...[
              const SizedBox(height: 16),
              Text('WhatsApp — tap each to open a chat:', style: Theme.of(context).textTheme.titleSmall),
              for (final r in whatsappRecipients)
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(r.name),
                  subtitle: Text(r.phone),
                  onTap: () => _openWhatsAppReminder(a, r.name, r.phone),
                ),
            ],
          ],
        ),
      ),
    );
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
