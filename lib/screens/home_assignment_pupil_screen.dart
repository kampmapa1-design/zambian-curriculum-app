import 'package:flutter/material.dart';

import '../models/home_assignment.dart';
import '../services/home_assignment_service.dart';
import '../services/pupil_class_link_service.dart';
import 'home_assignment_pupil_detail_screen.dart';
import 'join_class_pupil_screen.dart';

/// Home Assignment epic, Stages 7-8 — a linked pupil's own list of
/// issued Home Assignments for their class. Tapping one opens
/// [HomeAssignmentPupilDetailScreen] (view + submit, gated by Stage 4's
/// ad-gate). A pupil not yet linked to a class sees a real prompt to
/// join one — no fabricated content shown here either way.
class HomeAssignmentPupilScreen extends StatefulWidget {
  const HomeAssignmentPupilScreen({super.key});

  @override
  State<HomeAssignmentPupilScreen> createState() => _HomeAssignmentPupilScreenState();
}

class _HomeAssignmentPupilScreenState extends State<HomeAssignmentPupilScreen> {
  final _linkService = PupilClassLinkService();
  bool _loading = true;
  String? _schoolId;
  String? _classId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final claim = await _linkService.currentPupilClaim();
    if (!mounted) return;
    setState(() {
      _schoolId = claim.schoolId;
      _classId = claim.classId;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home Assignment')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_schoolId == null || _classId == null)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.group_add_outlined, size: 56),
                        const SizedBox(height: 16),
                        const Text("You're not linked to a class yet — join one to receive assignments here.", textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: () async {
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const JoinClassPupilScreen()));
                            if (mounted) _load();
                          },
                          child: const Text('Join a Class'),
                        ),
                      ],
                    ),
                  ),
                )
              : StreamBuilder<List<IssuedHomeAssignment>>(
                  stream: HomeAssignmentService().watchAssignments(_schoolId!, _classId!),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                    final assignments = snapshot.data!;
                    if (assignments.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('No home assignments have been sent to your class yet.')),
                      );
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
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => HomeAssignmentPupilDetailScreen(schoolId: _schoolId!, classId: _classId!, assignment: a)),
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
