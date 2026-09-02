import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/teacher_submission.dart';
import '../services/teacher_dashboard_service.dart';

/// Stage 13 — the teacher's individual-submission view: the processed
/// Word document and the original compressed images, toggled between
/// (opened externally via a fresh, short-lived signed URL each time —
/// see TeacherDashboardService.fileUrl), plus the integrity record
/// (hash + timestamp) and, contextually, either the student's declared
/// reference system (assignments) or the detected question-number
/// structure (tests).
class SubmissionDetailScreen extends StatefulWidget {
  const SubmissionDetailScreen({super.key, required this.submission, this.dashboardService});

  final TeacherSubmission submission;
  final TeacherDashboardService? dashboardService;

  @override
  State<SubmissionDetailScreen> createState() => _SubmissionDetailScreenState();
}

class _SubmissionDetailScreenState extends State<SubmissionDetailScreen> {
  late final TeacherDashboardService _dashboardService = widget.dashboardService ?? TeacherDashboardService();
  bool _opening = false;

  SubmissionFile? _fileEndingWith(String suffix) {
    for (final f in widget.submission.files) {
      if (f.filename.toLowerCase().endsWith(suffix)) return f;
    }
    return null;
  }

  SubmissionFile? get _docFile => _fileEndingWith('.docx');
  SubmissionFile? get _imageFile => _fileEndingWith('.pdf');

  Future<void> _open(SubmissionFile? file) async {
    if (file == null) return;
    setState(() => _opening = true);
    try {
      final url = await _dashboardService.fileUrl(widget.submission, file);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } on TeacherDashboardUnavailable catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final submission = widget.submission;
    final isAssignment = submission.kind == SubmissionKind.assignment;
    return Scaffold(
      appBar: AppBar(title: Text(submission.title.isEmpty ? submission.studentName : submission.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(submission.title.isEmpty ? '(untitled)' : submission.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('${submission.kind.label} · ${submission.studentName}'),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('Class / Grade', submission.className),
                  _row('Subject', submission.subjectName),
                  _row('Submitted', submission.submittedAt.toLocal().toString()),
                  _row('SHA-256', submission.sha256Hash),
                  _row(
                    isAssignment ? 'Reference System' : 'Question Structure',
                    submission.referenceInfo.isEmpty ? '(none)' : submission.referenceInfo,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('Files', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_opening) const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())),
          OutlinedButton.icon(
            onPressed: _docFile == null || _opening ? null : () => _open(_docFile),
            icon: const Icon(Icons.description_outlined),
            label: const Text('Open Processed Word Document'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _imageFile == null || _opening ? null : () => _open(_imageFile),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Open Original Photos (PDF)'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: RichText(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style,
            children: [
              TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
              TextSpan(text: value, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ],
          ),
        ),
      );
}
