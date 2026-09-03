import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/generated_report_form.dart';
import '../models/report_class.dart';
import '../services/assignment_submission_email_service.dart';
import '../services/generated_report_form_repository.dart';
import '../services/report_class_repository.dart';
import 'head_teacher_approval_screen.dart';
import 'report_form_generation_screen.dart';

/// Report Form Pipeline — every generated report for one class. Stage 12's
/// "Approve & Sign" lives here (an AppBar action, whenever at least one
/// unsigned report exists); Stage 13 (resend on demand) and Stage 14
/// (print) are the same per-row actions available right after Stage 10
/// generates a report in the first place — there's no separate "already
/// sent" state to track, "Send" always just works whenever tapped. Stage
/// 15's transmission reuses this app's existing patterns exactly: real
/// automatic email (AssignmentSubmissionEmailService, submissionKind:
/// 'reportForm'), the same wa.me WhatsApp deep-link used by Assignment/
/// Test Submission, and — genuinely new, since no SMS capability exists
/// anywhere else in this app — a plain `sms:` URI via url_launcher that
/// opens the device's own SMS app pre-filled with a short text pointer
/// (SMS cannot carry a file attachment at all, ever, on any platform —
/// disclosed plainly in the UI rather than pretended otherwise).
class ReportFormListScreen extends StatefulWidget {
  const ReportFormListScreen({
    super.key,
    required this.reportClass,
    this.repository,
    this.reportFormRepository,
  });

  final ReportClass reportClass;
  final ReportClassRepository? repository;
  final GeneratedReportFormRepository? reportFormRepository;

  @override
  State<ReportFormListScreen> createState() => _ReportFormListScreenState();
}

class _ReportFormListScreenState extends State<ReportFormListScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  late final GeneratedReportFormRepository _reportFormRepository =
      widget.reportFormRepository ?? GeneratedReportFormRepository();
  final _emailService = AssignmentSubmissionEmailService();

  List<GeneratedReportForm> _reports = const [];
  Map<int, ReportLearner> _learnersById = {};
  bool _loading = true;
  String? _busyReportId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final reports = await _reportFormRepository.listForClass(widget.reportClass.id);
    final learners = await _repository.listLearners(widget.reportClass.id);
    if (!mounted) return;
    setState(() {
      _reports = reports;
      _learnersById = {for (final l in learners) l.id: l};
      _loading = false;
    });
  }

  Future<void> _generateOrRegenerate() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportFormGenerationScreen(
          reportClass: widget.reportClass,
          repository: _repository,
          reportFormRepository: _reportFormRepository,
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _approveAndSign() async {
    final unsigned = _reports.where((r) => !r.signed).toList();
    if (unsigned.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HeadTeacherApprovalScreen(
          reportClass: widget.reportClass,
          reportsToSign: unsigned,
          repository: _repository,
          reportFormRepository: _reportFormRepository,
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _print(GeneratedReportForm report) async {
    final file = await _reportFormRepository.fileFor(report);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Report Form — ${report.learnerName}'));
  }

  Future<void> _send(GeneratedReportForm report) async {
    final learner = _learnersById[report.learnerId];
    final result = await showModalBottomSheet<_SendChoice>(
      context: context,
      builder: (sheetContext) => _SendSheet(learner: learner),
    );
    if (result == null || !mounted) return;

    setState(() => _busyReportId = report.id);
    try {
      switch (result.channel) {
        case _SendChannel.email:
          await _sendByEmail(report, result.contact);
        case _SendChannel.whatsApp:
          await _sendByWhatsApp(report, result.contact);
        case _SendChannel.sms:
          await _sendBySms(report, result.contact);
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send: $error')));
    } finally {
      if (mounted) setState(() => _busyReportId = null);
    }
  }

  Future<void> _sendByEmail(GeneratedReportForm report, String email) async {
    final file = await _reportFormRepository.fileFor(report);
    await _emailService.send(
      recipientEmail: email,
      studentName: report.learnerName,
      assignmentTitle: 'Report Form — ${widget.reportClass.classGrade}, ${widget.reportClass.term}',
      submissionHash: report.submissionHash,
      submittedAt: report.generatedAt,
      attachments: [EmailAttachmentFile(file: file, filename: '${report.learnerName} Report Form.docx')],
      submissionKind: 'reportForm',
    );
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report emailed.')));
  }

  Future<void> _sendByWhatsApp(GeneratedReportForm report, String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '').replaceAll('+', '');
    if (digits.length < 7) throw const FormatException('That phone number looks too short for WhatsApp.');
    final subject = 'Report Form — ${report.learnerName} (${widget.reportClass.classGrade})';
    final waUri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent('$subject — attaching the file next.')}');
    final opened = await launchUrl(waUri, mode: LaunchMode.externalApplication);
    if (!opened || !mounted) return;
    final file = await _reportFormRepository.fileFor(report);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path)],
      subject: subject,
      text: 'Attach to the WhatsApp chat that just opened.',
    ));
  }

  Future<void> _sendBySms(GeneratedReportForm report, String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.length < 7) throw const FormatException('That phone number looks too short.');
    final body = '${report.learnerName}\'s report form (${widget.reportClass.classGrade}) is ready — '
        'please contact the school to collect it, or ask for it by email/WhatsApp.';
    final smsUri = Uri(scheme: 'sms', path: digits, queryParameters: {'body': body});
    final opened = await launchUrl(smsUri);
    if (!opened) throw const FormatException('Could not open the SMS app.');
  }

  @override
  Widget build(BuildContext context) {
    final unsignedCount = _reports.where((r) => !r.signed).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Report Forms'),
        actions: [
          if (unsignedCount > 0)
            TextButton.icon(
              onPressed: _approveAndSign,
              icon: const Icon(Icons.verified_outlined, color: Colors.white),
              label: Text('Approve & Sign ($unsignedCount)', style: const TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _reports.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('No report forms generated yet for this class.', textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _generateOrRegenerate,
                          icon: const Icon(Icons.description_outlined),
                          label: const Text('Create Report Form'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  itemCount: _reports.length,
                  itemBuilder: (context, index) {
                    final report = _reports[index];
                    final busy = _busyReportId == report.id;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(
                          report.signed ? Icons.verified : Icons.hourglass_empty,
                          color: report.signed ? Colors.green : null,
                        ),
                        title: Text(report.learnerName),
                        subtitle: Text(report.signed ? 'Signed by ${report.signedByName}' : 'Not yet approved'),
                        trailing: busy
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(icon: const Icon(Icons.print_outlined), onPressed: () => _print(report)),
                                  IconButton(icon: const Icon(Icons.send_outlined), onPressed: () => _send(report)),
                                ],
                              ),
                      ),
                    );
                  },
                ),
      floatingActionButton: _loading || _reports.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _generateOrRegenerate,
              icon: const Icon(Icons.refresh),
              label: const Text('Re-generate All'),
            ),
    );
  }
}

enum _SendChannel { email, whatsApp, sms }

class _SendChoice {
  final _SendChannel channel;
  final String contact;
  const _SendChoice(this.channel, this.contact);
}

class _SendSheet extends StatefulWidget {
  const _SendSheet({required this.learner});
  final ReportLearner? learner;

  @override
  State<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<_SendSheet> {
  late final _emailController = TextEditingController(text: widget.learner?.guardianEmail ?? '');
  late final _phoneController = TextEditingController(text: widget.learner?.guardianPhone ?? '');

  @override
  void dispose() {
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Send Report Form', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _emailController,
              decoration: const InputDecoration(labelText: 'Guardian email', border: OutlineInputBorder()),
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _emailController.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(_SendChoice(_SendChannel.email, _emailController.text.trim())),
              icon: const Icon(Icons.email_outlined),
              label: const Text('Send by Email'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _phoneController,
              decoration: const InputDecoration(labelText: 'Guardian phone', border: OutlineInputBorder()),
              keyboardType: TextInputType.phone,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _phoneController.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(_SendChoice(_SendChannel.whatsApp, _phoneController.text.trim())),
              icon: const Icon(Icons.chat_outlined),
              label: const Text('Send by WhatsApp'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _phoneController.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(_SendChoice(_SendChannel.sms, _phoneController.text.trim())),
              icon: const Icon(Icons.sms_outlined),
              label: const Text('Notify by SMS (text only, no attachment)'),
            ),
          ],
        ),
      ),
    );
  }
}
