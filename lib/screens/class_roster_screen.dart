import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/report_class.dart';
import '../services/assignment_submission_email_service.dart';
import '../services/report_class_repository.dart';
import '../services/roster_confirmation_document_service.dart';
import '../services/roster_upload_session_repository.dart';

/// Report Form Pipeline — "Complete Session Upload" (2026-09-04, per
/// explicit request): the grade teacher's checkpoint for "I'm done adding
/// students to this class." Before that, this screen is just the roster
/// as it stands so far (rename/delete only — adding a missed learner still
/// goes through Omitted Entry, this screen doesn't duplicate that). Once
/// marked complete, every learner's guardian email and phone become
/// editable right here — the phone number covers BOTH WhatsApp and SMS
/// (a parent's number is the same for both; ReportLearner has always had
/// exactly one `guardianPhone` field, not two), and "Notify" (per learner
/// or, for email, all at once) sends a real registration-confirmation
/// document — nothing claims a score or result this early, report forms
/// are a separate, later stage.
///
/// Bulk sending is only genuinely one-tap for email — a real Android/
/// WhatsApp platform limit, not a shortcut taken here: no app can hand
/// WhatsApp or the SMS app a specific contact and message without the
/// user's own tap for THAT contact, so "notify everyone by WhatsApp/SMS
/// in one tap" isn't actually achievable on this platform. Each learner's
/// own "Notify" button covers all three channels for that one guardian.
class ClassRosterScreen extends StatefulWidget {
  const ClassRosterScreen({super.key, required this.reportClass, this.repository});

  final ReportClass reportClass;
  final ReportClassRepository? repository;

  @override
  State<ClassRosterScreen> createState() => _ClassRosterScreenState();
}

class _ClassRosterScreenState extends State<ClassRosterScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  final _sessionRepository = RosterUploadSessionRepository();
  final _confirmationService = RosterConfirmationDocumentService();
  final _emailService = AssignmentSubmissionEmailService();

  List<ReportLearner> _learners = const [];
  DateTime? _completedAt;
  bool _loading = true;
  int? _busyLearnerId;
  bool _bulkEmailing = false;

  // Guardian-contact field controllers, keyed by learner id — only
  // populated (and shown) once the session is marked complete.
  final Map<int, TextEditingController> _emailControllers = {};
  final Map<int, TextEditingController> _phoneControllers = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _emailControllers.values) {
      c.dispose();
    }
    for (final c in _phoneControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final learners = await _repository.listLearners(widget.reportClass.id);
    final completedAt = await _sessionRepository.completedAt(widget.reportClass.id);
    final sorted = [...learners]..sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));

    for (final c in _emailControllers.values) {
      c.dispose();
    }
    for (final c in _phoneControllers.values) {
      c.dispose();
    }
    _emailControllers.clear();
    _phoneControllers.clear();
    for (final learner in sorted) {
      _emailControllers[learner.id] = TextEditingController(text: learner.guardianEmail ?? '');
      _phoneControllers[learner.id] = TextEditingController(text: learner.guardianPhone ?? '');
    }

    if (!mounted) return;
    setState(() {
      _learners = sorted;
      _completedAt = completedAt;
      _loading = false;
    });
  }

  Future<void> _markComplete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Complete Session Upload?'),
        content: Text(
          'This confirms all ${_learners.length} learner(s) currently on the roster are correct and '
          'ready. You can still edit names and guardian contacts here afterwards — this just marks '
          'the initial upload as done.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Complete Session Upload')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _sessionRepository.markCompleted(widget.reportClass.id);
    if (mounted) _load();
  }

  Future<void> _reopen() async {
    await _sessionRepository.reopen(widget.reportClass.id);
    if (mounted) _load();
  }

  Future<void> _renameLearner(ReportLearner learner) async {
    final controller = TextEditingController(text: learner.fullName);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName.isEmpty || newName == learner.fullName) return;
    await _repository.renameLearner(learner.id, newName);
    if (mounted) _load();
  }

  Future<void> _deleteLearner(ReportLearner learner) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sure you want to delete?'),
        content: Text('This permanently removes ${learner.fullName} from the roster. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.deleteLearner(learner.id);
    if (mounted) _load();
  }

  Future<void> _saveGuardianContact(ReportLearner learner) async {
    await _repository.updateGuardianContact(
      learner.id,
      email: _emailControllers[learner.id]?.text,
      phone: _phoneControllers[learner.id]?.text,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved ${learner.fullName}\'s contact details.')));
    _load();
  }

  /// Generates the registration confirmation once, uses it for whichever
  /// of email/WhatsApp the teacher picks — real file, not text alone (see
  /// this screen's own doc comment on why that matters).
  Future<void> _notifyOne(ReportLearner learner) async {
    final email = learner.guardianEmail?.trim() ?? '';
    final phone = learner.guardianPhone?.trim() ?? '';
    if (email.isEmpty && phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No guardian email or phone on file for ${learner.fullName} yet.')),
      );
      return;
    }

    final selected = await showModalBottomSheet<Set<_NotifyChannel>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _NotifyChannelSheet(learner: learner, hasEmail: email.isNotEmpty, hasPhone: phone.isNotEmpty),
    );
    if (selected == null || selected.isEmpty || !mounted) return;

    setState(() => _busyLearnerId = learner.id);
    try {
      final file = await _confirmationService.generate(reportClass: widget.reportClass, learner: learner);
      final succeeded = <String>[];
      final failed = <String>[];

      if (selected.contains(_NotifyChannel.email)) {
        try {
          await _sendEmail(file, learner, email);
          succeeded.add('Email');
        } catch (e) {
          failed.add('Email ($e)');
        }
      }
      if (selected.contains(_NotifyChannel.whatsApp)) {
        try {
          await SharePlus.instance.share(ShareParams(
            files: [XFile(file.path)],
            subject: 'Registration Confirmation — ${learner.fullName}',
            text: 'Registration confirmation for ${learner.fullName} (${widget.reportClass.classGrade}) — for $phone.',
          ));
          succeeded.add('WhatsApp (share sheet opened)');
        } catch (e) {
          failed.add('WhatsApp ($e)');
        }
      }
      if (selected.contains(_NotifyChannel.sms)) {
        try {
          await _sendSms(learner, phone);
          succeeded.add('SMS');
        } catch (e) {
          failed.add('SMS ($e)');
        }
      }

      if (!mounted) return;
      final summary = [
        if (succeeded.isNotEmpty) '${succeeded.join(', ')} done.',
        if (failed.isNotEmpty) 'Failed: ${failed.join('; ')}.',
      ].join(' ');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary)));
    } finally {
      if (mounted) setState(() => _busyLearnerId = null);
    }
  }

  Future<void> _sendEmail(File file, ReportLearner learner, String email) async {
    final bytes = await file.readAsBytes();
    await _emailService.send(
      recipientEmail: email,
      studentName: learner.fullName,
      assignmentTitle: 'Class Registration — ${widget.reportClass.classGrade}, ${widget.reportClass.term}',
      submissionHash: sha256.convert(bytes).toString(),
      submittedAt: DateTime.now(),
      attachments: [EmailAttachmentFile(file: file, filename: '${learner.fullName} Registration Confirmation.docx')],
      submissionKind: 'rosterConfirmation',
    );
  }

  Future<void> _sendSms(ReportLearner learner, String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.length < 7) throw const FormatException('That phone number looks too short.');
    final body = '${learner.fullName} is registered in ${widget.reportClass.classGrade} '
        '(${widget.reportClass.term}). Report forms will follow separately.';
    final smsUri = Uri(scheme: 'sms', path: digits, queryParameters: {'body': body});
    final opened = await launchUrl(smsUri);
    if (!opened) throw const FormatException('Could not open the SMS app.');
  }

  /// The only channel that's genuinely one-tap-for-everyone — see this
  /// screen's own doc comment on why WhatsApp/SMS can't work the same way.
  Future<void> _notifyAllByEmail() async {
    final withEmail = _learners.where((l) => (l.guardianEmail ?? '').trim().isNotEmpty).toList();
    if (withEmail.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No guardian emails on file yet.')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Email all guardians?'),
        content: Text('Sends a registration confirmation to all ${withEmail.length} guardian email(s) on file. '
            'WhatsApp and SMS can\'t be sent in bulk like this — Android requires your own tap per contact for '
            'those, so use each learner\'s own "Notify" button for those channels.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Email All')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _bulkEmailing = true);
    var sent = 0;
    var failed = 0;
    try {
      for (final learner in withEmail) {
        try {
          final file = await _confirmationService.generate(reportClass: widget.reportClass, learner: learner);
          await _sendEmail(file, learner, learner.guardianEmail!.trim());
          sent++;
        } catch (_) {
          failed++;
        }
      }
    } finally {
      if (mounted) setState(() => _bulkEmailing = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Emailed $sent guardian(s)${failed > 0 ? ' — $failed failed' : ''}.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isComplete = _completedAt != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Class Roster'),
        actions: [
          if (isComplete)
            IconButton(
              icon: const Icon(Icons.lock_open_outlined),
              tooltip: 'Reopen session',
              onPressed: _reopen,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!isComplete) ...[
                        Text(
                          '${_learners.length} learner(s) captured so far. Rename or delete any incorrect entry '
                          'below — to add someone missed, use Omitted Entry on the Broad Mark Sheet.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _learners.isEmpty ? null : _markComplete,
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text('Complete Session Upload'),
                        ),
                      ] else ...[
                        Row(
                          children: [
                            const Icon(Icons.verified, color: Colors.green, size: 18),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Session upload completed ${_formatDateTime(_completedAt!)} — enter guardian '
                                'contacts below.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _bulkEmailing ? null : _notifyAllByEmail,
                          icon: _bulkEmailing
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.mark_email_read_outlined),
                          label: Text(_bulkEmailing ? 'Emailing…' : 'Notify All Guardians (Email)'),
                        ),
                      ],
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _learners.isEmpty
                      ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No learners yet.')))
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _learners.length,
                          itemBuilder: (context, index) => _learnerCard(_learners[index], isComplete),
                        ),
                ),
              ],
            ),
    );
  }

  String _formatDateTime(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Widget _learnerCard(ReportLearner learner, bool isComplete) {
    final busy = _busyLearnerId == learner.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(learner.fullName, style: Theme.of(context).textTheme.titleSmall),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Edit name',
                  onPressed: () => _renameLearner(learner),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, size: 20, color: Theme.of(context).colorScheme.error),
                  tooltip: 'Delete',
                  onPressed: () => _deleteLearner(learner),
                ),
              ],
            ),
            if (isComplete) ...[
              const SizedBox(height: 4),
              TextField(
                controller: _emailControllers[learner.id],
                decoration: const InputDecoration(
                  labelText: 'Guardian email',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _phoneControllers[learner.id],
                decoration: const InputDecoration(
                  labelText: 'Guardian phone (WhatsApp + SMS)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _saveGuardianContact(learner),
                      icon: const Icon(Icons.save_outlined, size: 16),
                      label: const Text('Save Contact'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: busy ? null : () => _notifyOne(learner),
                      icon: busy
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_outlined, size: 16),
                      label: Text(busy ? 'Sending…' : 'Notify'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _NotifyChannel { email, whatsApp, sms }

class _NotifyChannelSheet extends StatefulWidget {
  const _NotifyChannelSheet({required this.learner, required this.hasEmail, required this.hasPhone});

  final ReportLearner learner;
  final bool hasEmail;
  final bool hasPhone;

  @override
  State<_NotifyChannelSheet> createState() => _NotifyChannelSheetState();
}

class _NotifyChannelSheetState extends State<_NotifyChannelSheet> {
  final Set<_NotifyChannel> _selected = {};

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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Notify ${widget.learner.fullName}\'s guardian', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (widget.hasEmail)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _selected.contains(_NotifyChannel.email),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _selected.add(_NotifyChannel.email);
                    } else {
                      _selected.remove(_NotifyChannel.email);
                    }
                  }),
                  title: const Text('Email — attaches the confirmation'),
                ),
              if (widget.hasPhone) ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _selected.contains(_NotifyChannel.whatsApp),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _selected.add(_NotifyChannel.whatsApp);
                    } else {
                      _selected.remove(_NotifyChannel.whatsApp);
                    }
                  }),
                  title: const Text('WhatsApp — attaches the confirmation; pick the contact within WhatsApp'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _selected.contains(_NotifyChannel.sms),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _selected.add(_NotifyChannel.sms);
                    } else {
                      _selected.remove(_NotifyChannel.sms);
                    }
                  }),
                  title: const Text('SMS — text only, no attachment'),
                ),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _selected.isEmpty ? null : () => Navigator.of(context).pop(_selected),
                icon: const Icon(Icons.send_outlined),
                label: const Text('Send'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
