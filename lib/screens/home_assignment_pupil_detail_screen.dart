import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/home_assignment.dart';
import '../services/home_assignment_service.dart';
import '../widgets/home_assignment_ad_gate.dart';
import 'document_pages_capture_screen.dart';

/// Home Assignment epic, Stage 8 — a pupil's own view of one issued
/// assignment, plus submission (gated by Stage 4's ad-gate — "applies to
/// submission only, not to receiving/viewing"). A successful submission
/// queues automatically in the teacher's queue, pre-tagged to this
/// assignment's marking key, via `recordHomeAssignmentSubmission`.
class HomeAssignmentPupilDetailScreen extends StatefulWidget {
  const HomeAssignmentPupilDetailScreen({required this.schoolId, required this.classId, required this.assignment, super.key});
  final String schoolId;
  final String classId;
  final IssuedHomeAssignment assignment;

  @override
  State<HomeAssignmentPupilDetailScreen> createState() => _HomeAssignmentPupilDetailScreenState();
}

class _HomeAssignmentPupilDetailScreenState extends State<HomeAssignmentPupilDetailScreen> {
  final _service = HomeAssignmentService();
  bool _submitting = false;
  bool _submitted = false;

  Future<void> _submit() async {
    final pages = await Navigator.of(context).push<List<File>>(
      MaterialPageRoute(
        builder: (_) => DocumentPagesCaptureScreen(
          title: 'Capture Your Answers',
          instructions: 'Photograph each page of your answers, in order.',
        ),
      ),
    );
    if (pages == null || pages.isEmpty || !mounted) return;

    final adsWatched = await showHomeAssignmentAdGate(context);
    if (!adsWatched || !mounted) return;

    setState(() => _submitting = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final paths = <String>[];
      for (var i = 0; i < pages.length; i++) {
        final bytes = await pages[i].readAsBytes();
        final path = await _service.uploadSubmissionPhoto(
          schoolId: widget.schoolId,
          classId: widget.classId,
          assignmentId: widget.assignment.id,
          uploaderUid: uid,
          index: i,
          bytes: bytes,
        );
        paths.add(path);
      }
      await _service.recordSubmission(
        schoolId: widget.schoolId,
        classId: widget.classId,
        assignmentId: widget.assignment.id,
        photoPaths: paths,
      );
      if (!mounted) return;
      setState(() => _submitted = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Submitted! Your teacher will mark it soon.')));
    } on HomeAssignmentException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assignment;
    return Scaffold(
      appBar: AppBar(title: Text(a.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${a.subjectName} · ${a.className}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          if (a.deadline != null) Text('Due: ${a.deadline!.day}/${a.deadline!.month}/${a.deadline!.year}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          if (a.instructions.trim().isNotEmpty) ...[
            Text(a.instructions),
            const SizedBox(height: 16),
          ],
          for (final q in a.questions)
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text(q.number)),
                title: Text(q.text),
                trailing: Text('${q.maxMarks.toStringAsFixed(q.maxMarks == q.maxMarks.roundToDouble() ? 0 : 1)} mk${q.maxMarks == 1 ? '' : 's'}'),
              ),
            ),
          const SizedBox(height: 24),
          if (_submitted)
            const Card(
              color: Colors.green,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Row(children: [Icon(Icons.check_circle, color: Colors.white), SizedBox(width: 12), Text('Submitted', style: TextStyle(color: Colors.white))]),
              ),
            )
          else
            FilledButton.icon(
              icon: _submitting ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Icon(Icons.camera_alt_outlined),
              label: Text(_submitting ? 'Submitting...' : 'Submit My Answers'),
              onPressed: _submitting ? null : _submit,
            ),
        ],
      ),
    );
  }
}
