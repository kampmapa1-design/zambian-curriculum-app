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

  /// Sends via every channel the teacher checked in [_SendSheet] — real,
  /// reported request: "give sending to all channels at the same time"
  /// rather than forcing one channel per trip through this whole flow.
  /// Each channel is attempted independently (one failing — a malformed
  /// number, no email app installed — never stops the others), and the
  /// result is one consolidated summary rather than a separate dialog per
  /// channel.
  Future<void> _send(GeneratedReportForm report) async {
    final learner = _learnersById[report.learnerId];
    final result = await showModalBottomSheet<_SendSelection>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _SendSheet(learner: learner),
    );
    if (result == null || result.channels.isEmpty || !mounted) return;

    setState(() => _busyReportId = report.id);
    final succeeded = <String>[];
    final failed = <String>[];
    for (final channel in result.channels) {
      try {
        switch (channel) {
          case _SendChannel.email:
            await _sendByEmail(report, result.email);
            succeeded.add('Email');
          case _SendChannel.whatsApp:
            await _sendByWhatsApp(report, result.phone);
            succeeded.add('WhatsApp');
          case _SendChannel.sms:
            await _sendBySms(report, result.phone);
            succeeded.add('SMS');
        }
      } catch (error) {
        failed.add('${channel.label} ($error)');
      }
    }
    if (mounted) {
      final summary = [
        if (succeeded.isNotEmpty) '${succeeded.join(', ')} done.',
        if (failed.isNotEmpty) 'Failed: ${failed.join('; ')}.',
      ].join(' ');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary)));
      setState(() => _busyReportId = null);
    }
  }

  Future<void> _sendByEmail(GeneratedReportForm report, String email) async {
    if (email.trim().isEmpty) throw const FormatException('No guardian email given.');
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
  }

  /// One unmistakable action: shares the actual report FILE via the OS
  /// share sheet, same working pattern [_print] already uses — the
  /// teacher picks WhatsApp there, then the contact within WhatsApp
  /// itself. Real, reported bug fixed here: the previous two-step flow
  /// (a `wa.me` text-only deep link opening a specific chat, THEN a
  /// second, easy-to-miss share-sheet prompt for the actual file) meant
  /// most teachers only ever completed the first step — the text message
  /// sent, the file never actually attached. There is no way to both
  /// pre-select a specific WhatsApp contact AND attach a file in one
  /// programmatic step on any platform (`wa.me` only ever supports plain
  /// text) — so this is the most reliable version of "send by WhatsApp"
  /// actually achievable, not a shortcut around a real limitation.
  Future<void> _sendByWhatsApp(GeneratedReportForm report, String phone) async {
    final file = await _reportFormRepository.fileFor(report);
    final subject = 'Report Form — ${report.learnerName} (${widget.reportClass.classGrade})';
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path)],
      subject: subject,
      text: phone.trim().isEmpty ? subject : '$subject — for $phone.',
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

enum _SendChannel {
  email,
  whatsApp,
  sms;

  String get label => switch (this) {
        _SendChannel.email => 'Email',
        _SendChannel.whatsApp => 'WhatsApp',
        _SendChannel.sms => 'SMS',
      };
}

class _SendSelection {
  final Set<_SendChannel> channels;
  final String email;
  final String phone;
  const _SendSelection({required this.channels, required this.email, required this.phone});
}

/// Real, reported bug fixed here (2026-09-03): with the on-screen keyboard
/// open, this sheet's own send options could end up pushed off-screen —
/// `showModalBottomSheet` without `isScrollControlled: true` (see [_send])
/// caps the sheet's height and does nothing to keep its content clear of
/// the keyboard beyond the [MediaQuery] padding already here; wrapping the
/// content in [SingleChildScrollView] means it scrolls instead of
/// clipping/overflowing once the keyboard and content together don't fit.
///
/// Checkboxes rather than one-tap-per-channel buttons, per explicit
/// request ("give sending to all channels at the same time") — a teacher
/// can tick Email, WhatsApp, and SMS together and fire all three with one
/// "Send" tap; [ReportFormListScreen._send] attempts every checked channel
/// independently and reports back one combined summary.
class _SendSheet extends StatefulWidget {
  const _SendSheet({required this.learner});
  final ReportLearner? learner;

  @override
  State<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<_SendSheet> {
  late final _emailController = TextEditingController(text: widget.learner?.guardianEmail ?? '');
  late final _phoneController = TextEditingController(text: widget.learner?.guardianPhone ?? '');
  final Set<_SendChannel> _selected = {};

  @override
  void dispose() {
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  bool _channelReady(_SendChannel channel) => switch (channel) {
        _SendChannel.email => _emailController.text.trim().isNotEmpty,
        _SendChannel.whatsApp || _SendChannel.sms => _phoneController.text.trim().isNotEmpty,
      };

  bool get _canSend => _selected.isNotEmpty && _selected.every(_channelReady);

  void _toggle(_SendChannel channel, bool? checked) => setState(() {
        if (checked == true) {
          _selected.add(channel);
        } else {
          _selected.remove(channel);
        }
      });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Send Report Form', style: Theme.of(context).textTheme.titleMedium)),
                  TextButton(
                    onPressed: () => setState(() => _selected.addAll(_SendChannel.values)),
                    child: const Text('Select all channels'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Guardian email', border: OutlineInputBorder()),
                keyboardType: TextInputType.emailAddress,
                onChanged: (_) => setState(() {}),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(_SendChannel.email),
                onChanged: (checked) => _toggle(_SendChannel.email, checked),
                title: const Text('Email — attaches the report form file'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'Guardian phone', border: OutlineInputBorder()),
                keyboardType: TextInputType.phone,
                onChanged: (_) => setState(() {}),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(_SendChannel.whatsApp),
                onChanged: (checked) => _toggle(_SendChannel.whatsApp, checked),
                title: const Text('WhatsApp — attaches the file; pick the contact within WhatsApp'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(_SendChannel.sms),
                onChanged: (checked) => _toggle(_SendChannel.sms, checked),
                title: const Text('SMS — text only, no attachment (SMS cannot carry a file)'),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _canSend
                    ? () => Navigator.of(context).pop(_SendSelection(
                          channels: _selected,
                          email: _emailController.text.trim(),
                          phone: _phoneController.text.trim(),
                        ))
                    : null,
                icon: const Icon(Icons.send_outlined),
                label: Text(_selected.isEmpty ? 'Select a channel above' : 'Send via ${_selected.map((c) => c.label).join(' + ')}'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
