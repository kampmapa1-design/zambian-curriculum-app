import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/marking_script.dart';
import '../models/teacher_submission.dart';
import '../services/submission_marking_bridge_service.dart';
import '../services/teacher_dashboard_service.dart';

/// Stage 13 — the teacher's individual-submission view: the processed
/// Word document and the original compressed images, toggled between
/// (opened externally via a fresh, short-lived signed URL each time —
/// see TeacherDashboardService.fileUrl), plus the integrity record
/// (hash + timestamp) and, contextually, either the student's declared
/// reference system (assignments) or the detected question-number
/// structure (tests).
class SubmissionDetailScreen extends StatefulWidget {
  const SubmissionDetailScreen({super.key, required this.submission, this.dashboardService, this.markingBridgeService});

  final TeacherSubmission submission;
  final TeacherDashboardService? dashboardService;
  final SubmissionMarkingBridgeService? markingBridgeService;

  @override
  State<SubmissionDetailScreen> createState() => _SubmissionDetailScreenState();
}

class _SubmissionDetailScreenState extends State<SubmissionDetailScreen> {
  late final TeacherDashboardService _dashboardService = widget.dashboardService ?? TeacherDashboardService();
  late final SubmissionMarkingBridgeService _markingBridgeService =
      widget.markingBridgeService ?? SubmissionMarkingBridgeService(dashboardService: _dashboardService);
  bool _opening = false;
  bool _sendingToMarking = false;

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

  Future<CandidateGender?> _askGender() {
    CandidateGender? gender;
    return showDialog<CandidateGender>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text("Student's gender"),
          content: SegmentedButton<CandidateGender>(
            segments: const [
              ButtonSegment(value: CandidateGender.male, label: Text('Male')),
              ButtonSegment(value: CandidateGender.female, label: Text('Female')),
            ],
            selected: {if (gender != null) gender!},
            emptySelectionAllowed: true,
            onSelectionChanged: (selection) => setDialogState(() => gender = selection.firstOrNull),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: gender == null ? null : () => Navigator.of(dialogContext).pop(gender),
              child: const Text('Add to Marking Queue'),
            ),
          ],
        ),
      ),
    );
  }

  /// "Mark Submitted Assignment" (owner request, 2026-09-28) — downloads
  /// this submission's photographed pages and adds them to the Marking
  /// Queue as a new script, ready for Chief Marker/Concise Marking/Stable
  /// Marker like any other captured script. See
  /// SubmissionMarkingBridgeService's own doc for why this needs a
  /// download-and-rasterize step (the Dashboard only ever has one merged
  /// PDF of the pages, never per-page images) and the disclosed limit on
  /// sending feedback back through this specific path.
  Future<void> _markSubmittedAssignment() async {
    final gender = await _askGender();
    if (gender == null || !mounted) return;

    setState(() => _sendingToMarking = true);
    try {
      final script = await _markingBridgeService.sendToMarking(submission: widget.submission, gender: gender);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added to Marking queue as script #${script.scriptNumber} — pick a marking key there when ready to grade.',
          ),
        ),
      );
    } on SubmissionMarkingBridgeUnavailable catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send this to marking: $error')));
      }
    } finally {
      if (mounted) setState(() => _sendingToMarking = false);
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
          if (isAssignment) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _imageFile == null || _sendingToMarking ? null : _markSubmittedAssignment,
              icon: _sendingToMarking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.fact_check_outlined),
              label: Text(_sendingToMarking ? 'Adding to Marking Queue…' : 'Mark Submitted Assignment'),
            ),
          ],
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
