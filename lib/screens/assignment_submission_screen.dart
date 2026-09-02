import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/assignment_submission.dart';
import '../services/assignment_submission_document_service.dart';
import '../services/assignment_submission_email_service.dart';
import '../services/assignment_submission_repository.dart';
import '../services/cover_page_extraction_service.dart';
import '../services/handwriting_document_transcription_service.dart';
import '../services/reference_page_transcription_service.dart';
import '../services/rewarded_ad_service.dart';
import 'document_pages_capture_screen.dart';

/// Whether Assignment Submission's rewarded-ad gate is active — Stage 10's
/// dormant scaffold, off by default so the feature is fully free during
/// testing. A single toggle activates it later without touching anything
/// else (see [_maybeShowAd]) — same pattern as `kEntitlementEnforced`/
/// `kGradingCapEnforced` elsewhere in this app.
const bool kAssignmentSubmissionAdGateEnabled = false;

enum _Step { cover, body, referenceSystem, references, review, transmit, receipt }

/// Assignment Submission — a student photographs their handwritten cover
/// page, main body, and (if used) reference/bibliography page; the app
/// transcribes each faithfully (never correcting or completing content
/// that's the student's own academic work to get right), consolidates
/// everything into one Word document plus a viewable PDF backup of every
/// original photo (2026-09-02: was a PDF + a .zip; now a Word doc + a
/// PDF, per explicit request — see AssignmentSubmissionDocumentService),
/// records a SHA-256 + timestamp as proof, and sends the result
/// to a teacher by email (fully automatic, via a real transactional
/// email backend) and/or WhatsApp (opens the chat pre-filled, one
/// manual tap to attach and send). Entirely offline through
/// consolidation (Stage 7) — only the AI transcription calls and the
/// final send need a connection.
class AssignmentSubmissionScreen extends StatefulWidget {
  const AssignmentSubmissionScreen({
    super.key,
    this.repository,
    this.coverPageExtractionService,
    this.bodyTranscriptionService,
    this.referenceTranscriptionService,
    this.documentService,
    this.emailService,
  });

  final AssignmentSubmissionRepository? repository;
  final CoverPageExtractionService? coverPageExtractionService;
  final HandwritingDocumentTranscriptionService? bodyTranscriptionService;
  final ReferencePageTranscriptionService? referenceTranscriptionService;
  final AssignmentSubmissionDocumentService? documentService;
  final AssignmentSubmissionEmailService? emailService;

  @override
  State<AssignmentSubmissionScreen> createState() => _AssignmentSubmissionScreenState();
}

class _AssignmentSubmissionScreenState extends State<AssignmentSubmissionScreen> {
  late final AssignmentSubmissionRepository _repository = widget.repository ?? AssignmentSubmissionRepository();
  late final CoverPageExtractionService _coverService = widget.coverPageExtractionService ?? CoverPageExtractionService();
  late final HandwritingDocumentTranscriptionService _bodyService =
      widget.bodyTranscriptionService ?? HandwritingDocumentTranscriptionService();
  late final ReferencePageTranscriptionService _referenceService =
      widget.referenceTranscriptionService ?? ReferencePageTranscriptionService();
  late final AssignmentSubmissionDocumentService _documentService = widget.documentService ?? AssignmentSubmissionDocumentService();
  late final AssignmentSubmissionEmailService _emailService = widget.emailService ?? AssignmentSubmissionEmailService();

  AssignmentSubmission? _submission;
  _Step _step = _Step.cover;
  bool _busy = false;
  String? _busyMessage;

  final _studentNameController = TextEditingController();
  final _idNumberController = TextEditingController();
  final _courseController = TextEditingController();
  final _subjectController = TextEditingController();
  final _titleController = TextEditingController();
  final _teacherNameController = TextEditingController();
  final _dateController = TextEditingController();
  final _institutionController = TextEditingController();
  final _emailController = TextEditingController();
  final _whatsAppController = TextEditingController();

  List<AssignmentBodyBlock> _bodyBlocks = [];
  final List<TextEditingController> _bodyControllers = [];
  List<String> _referenceEntries = [];
  final List<TextEditingController> _referenceControllers = [];
  ReferenceSystem _referenceSystem = ReferenceSystem.none;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final submission = await _repository.createDraft();
    if (!mounted) return;
    setState(() => _submission = submission);

    // The camera opens immediately, with nothing gating it (2026-09-02) —
    // matches Chief Marker's own capture screen, and fixes a real
    // complaint: entering this screen used to require an extra manual tap
    // on "Capture Cover Page" before the camera ever appeared, which read
    // as the home-screen button "not working". Backing out empty-handed
    // still leaves the ordinary manual "Capture Cover Page" button on
    // Stage 1 as a retry path — this call doesn't loop or force anything.
    await _captureCoverPage();
  }

  @override
  void dispose() {
    for (final c in [
      _studentNameController,
      _idNumberController,
      _courseController,
      _subjectController,
      _titleController,
      _teacherNameController,
      _dateController,
      _institutionController,
      _emailController,
      _whatsAppController,
    ]) {
      c.dispose();
    }
    for (final c in [..._bodyControllers, ..._referenceControllers]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _runBusy(String message, Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _busyMessage = message;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -------------------------------------------------------------------
  // Stage 1 — Cover page
  // -------------------------------------------------------------------

  Future<void> _captureCoverPage() async {
    final pages = await Navigator.of(context).push<List<File>?>(
      MaterialPageRoute(
        builder: (_) => const DocumentPagesCaptureScreen(
          title: 'Cover Page',
          instructions: 'Photograph your handwritten cover page, then tap Done.',
        ),
      ),
    );
    if (pages == null || pages.isEmpty || !mounted) return;

    await _runBusy('Reading cover page…', () async {
      final submission = _submission!;
      final fileName = await _repository.storeFile(submission, pages.first, 'cover.jpg');
      final updated = submission.copyWith(coverPhotoFileName: fileName);
      await _repository.update(updated);
      setState(() => _submission = updated);

      final fields = await _coverService.extract(pages.first);
      if (!mounted) return;
      setState(() {
        _studentNameController.text = fields.studentName;
        _idNumberController.text = fields.idNumber;
        _courseController.text = fields.course;
        _subjectController.text = fields.subject;
        _titleController.text = fields.assignmentTitle;
        _teacherNameController.text = fields.teacherName;
        _dateController.text = fields.date;
        _institutionController.text = fields.institution;
      });
      if (fields.notes.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Double-check: ${fields.notes}')));
      }
    });
  }

  Future<void> _confirmCoverFields() async {
    final submission = _submission!.copyWith(
      studentName: _studentNameController.text.trim(),
      idNumber: _idNumberController.text.trim(),
      course: _courseController.text.trim(),
      subject: _subjectController.text.trim(),
      assignmentTitle: _titleController.text.trim(),
      teacherName: _teacherNameController.text.trim(),
      date: _dateController.text.trim(),
      institution: _institutionController.text.trim(),
    );
    await _repository.update(submission);
    setState(() {
      _submission = submission;
      _step = _Step.body;
    });
  }

  // -------------------------------------------------------------------
  // Stage 2 — Main body
  // -------------------------------------------------------------------

  Future<void> _captureBody() async {
    final pages = await Navigator.of(context).push<List<File>?>(
      MaterialPageRoute(
        builder: (_) => const DocumentPagesCaptureScreen(
          title: 'Main Body',
          instructions: 'Photograph the Introduction, Main Body, and Conclusion pages, in order, then tap Done.',
        ),
      ),
    );
    if (pages == null || pages.isEmpty || !mounted) return;

    await _runBusy('Transcribing your work…', () async {
      final submission = _submission!;
      final fileNames = <String>[];
      for (var i = 0; i < pages.length; i++) {
        fileNames.add(await _repository.storeFile(submission, pages[i], 'body_${(i + 1).toString().padLeft(2, '0')}.jpg'));
      }
      var updated = submission.copyWith(bodyPageFileNames: fileNames);
      await _repository.update(updated);
      setState(() => _submission = updated);

      final transcribed = await _bodyService.transcribe(pages);
      final blocks = [
        for (final b in transcribed.blocks)
          AssignmentBodyBlock(
            type: AssignmentBodyBlockType.values.firstWhere(
              (t) => t.name == b.type.name,
              orElse: () => AssignmentBodyBlockType.paragraph,
            ),
            text: b.text,
          ),
      ];
      updated = updated.copyWith(transcribedBody: blocks);
      await _repository.update(updated);
      if (!mounted) return;
      setState(() {
        _submission = updated;
        _bodyBlocks = blocks;
        for (final c in _bodyControllers) {
          c.dispose();
        }
        _bodyControllers
          ..clear()
          ..addAll([for (final b in blocks) TextEditingController(text: b.text)]);
      });
      if (transcribed.notes.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Double-check: ${transcribed.notes}')));
      }
    });
  }

  void _confirmBody() {
    final edited = [
      for (var i = 0; i < _bodyBlocks.length; i++) AssignmentBodyBlock(type: _bodyBlocks[i].type, text: _bodyControllers[i].text),
    ];
    setState(() {
      _bodyBlocks = edited;
      _submission = _submission!.copyWith(transcribedBody: edited);
      _step = _Step.referenceSystem;
    });
    _repository.update(_submission!);
  }

  // -------------------------------------------------------------------
  // Stage 3 — Reference system
  // -------------------------------------------------------------------

  void _chooseReferenceSystem(ReferenceSystem system) {
    final submission = _submission!.copyWith(referenceSystem: system);
    _repository.update(submission);
    setState(() {
      _submission = submission;
      _referenceSystem = system;
      _step = system == ReferenceSystem.none ? _Step.review : _Step.references;
    });
  }

  // -------------------------------------------------------------------
  // Stage 4 — Reference / bibliography page
  // -------------------------------------------------------------------

  Future<void> _captureReferences() async {
    final pages = await Navigator.of(context).push<List<File>?>(
      MaterialPageRoute(
        builder: (_) => const DocumentPagesCaptureScreen(
          title: 'Reference Page',
          instructions: 'Photograph your reference/bibliography page(s), in order, then tap Done.',
        ),
      ),
    );
    if (pages == null || pages.isEmpty || !mounted) return;

    await _runBusy('Transcribing references…', () async {
      final submission = _submission!;
      final fileNames = <String>[];
      for (var i = 0; i < pages.length; i++) {
        fileNames.add(await _repository.storeFile(submission, pages[i], 'reference_${(i + 1).toString().padLeft(2, '0')}.jpg'));
      }
      var updated = submission.copyWith(referencePageFileNames: fileNames);
      await _repository.update(updated);
      setState(() => _submission = updated);

      final transcribed = await _referenceService.transcribe(pageFiles: pages, referenceSystem: _referenceSystem);
      updated = updated.copyWith(transcribedReferences: transcribed.entries);
      await _repository.update(updated);
      if (!mounted) return;
      setState(() {
        _submission = updated;
        _referenceEntries = transcribed.entries;
        for (final c in _referenceControllers) {
          c.dispose();
        }
        _referenceControllers
          ..clear()
          ..addAll([for (final e in transcribed.entries) TextEditingController(text: e)]);
      });
      if (transcribed.notes.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Double-check: ${transcribed.notes}')));
      }
    });
  }

  void _confirmReferences() {
    final edited = [for (final c in _referenceControllers) c.text];
    setState(() {
      _referenceEntries = edited;
      _submission = _submission!.copyWith(transcribedReferences: edited);
      _step = _Step.review;
    });
    _repository.update(_submission!);
  }

  // -------------------------------------------------------------------
  // Stage 5-7 — Consolidate
  // -------------------------------------------------------------------

  Future<void> _consolidate() async {
    await _maybeShowAd();
    await _runBusy('Building your submission…', () async {
      final submission = _submission!;
      final dir = await _repository.submissionDir(submission);
      final submittedAt = DateTime.now();
      final doc = await _documentService.generateConsolidatedDocx(
        submission: submission,
        submissionDir: dir,
        submittedAt: submittedAt,
      );
      await _documentService.generateImageBundle(submission: submission, submissionDir: dir);
      final hash = await _documentService.computeSha256(doc);

      final updated = submission.copyWith(
        status: AssignmentSubmissionStatus.consolidated,
        docFileName: 'submission.docx',
        imageBundleFileName: 'original_pages.pdf',
        sha256Hash: hash,
        submittedAt: submittedAt,
      );
      await _repository.update(updated);
      if (!mounted) return;
      setState(() {
        _submission = updated;
        _step = _Step.transmit;
      });
    });
  }

  /// Stage 10 — dormant by default (see [kAssignmentSubmissionAdGateEnabled]).
  /// Mirrors this app's existing rewarded-ad pattern (RewardedAdService) —
  /// left as a stub call so flipping the flag on later is the only change
  /// needed, not a rebuild of this screen.
  Future<void> _maybeShowAd() async {
    if (!kAssignmentSubmissionAdGateEnabled) return;
    await RewardedAdService.instance.showAd();
  }

  // -------------------------------------------------------------------
  // Stage 8 — Transmission
  // -------------------------------------------------------------------

  /// Email is genuinely automatic (added 2026-09-01): the Word doc and
  /// image-PDF go straight to the teacher's inbox via a real transactional
  /// email backend (Resend, called through `sendAssignmentSubmissionEmail`)
  /// with no further tap from the student. WhatsApp is the one channel
  /// that still needs a manual tap — there's no WhatsApp *sending* API
  /// wired into this app (Meta's official one requires business approval
  /// and a paid setup far beyond this project's scope), so it goes
  /// through the OS share sheet instead. It still gets a real advantage
  /// over plain sharing: opening the chat with the entered number
  /// pre-filled via `wa.me` before the share sheet, so the student lands
  /// on the right conversation rather than picking a contact from
  /// scratch.
  Future<void> _send() async {
    final email = _emailController.text.trim();
    final whatsApp = _whatsAppController.text.trim();
    if (email.isEmpty && whatsApp.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a teacher email and/or WhatsApp number to send.')),
      );
      return;
    }

    await _runBusy('Sending…', () async {
      final submission = _submission!;
      final dir = await _repository.submissionDir(submission);
      final docFile = _repository.fileFor(submission, dir, submission.docFileName!);
      final bundleFile = _repository.fileFor(submission, dir, submission.imageBundleFileName!);
      final subject = 'Assignment Submission — ${submission.assignmentTitle.isEmpty ? submission.studentName : submission.assignmentTitle}';

      var emailSent = false;
      String? emailMessageId;
      if (email.isNotEmpty) {
        try {
          emailMessageId = await _emailService.send(
            recipientEmail: email,
            studentName: submission.studentName,
            assignmentTitle: submission.assignmentTitle,
            submissionHash: submission.sha256Hash ?? '',
            submittedAt: submission.submittedAt ?? DateTime.now(),
            attachments: [
              EmailAttachmentFile(file: docFile, filename: submission.docFileName!),
              EmailAttachmentFile(file: bundleFile, filename: submission.imageBundleFileName!),
            ],
          );
          emailSent = true;
        } on AssignmentSubmissionEmailUnavailable catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Email not sent: $e')));
          }
        }
      }

      var whatsAppOpened = false;
      if (whatsApp.isNotEmpty) {
        final digits = whatsApp.replaceAll(RegExp(r'[^0-9+]'), '').replaceAll('+', '');
        if (digits.length < 7) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("That WhatsApp number doesn't look valid — include the country code.")),
            );
          }
        } else {
          final waUri =
              Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent('$subject — attaching the file(s) next.')}');
          whatsAppOpened = await launchUrl(waUri, mode: LaunchMode.externalApplication);
        }
        if (whatsAppOpened && mounted) {
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(docFile.path), XFile(bundleFile.path)],
              subject: subject,
              text: 'Attach to the WhatsApp chat that just opened.',
            ),
          );
        }
      }

      // If the only channel(s) the student entered all failed (email
      // rejected, WhatsApp didn't open), stay on this step so they can
      // retry rather than showing a false "Submission Complete" receipt.
      if (!emailSent && !whatsAppOpened) return;

      final updated = submission.copyWith(
        teacherEmail: email.isEmpty ? null : email,
        teacherWhatsApp: whatsApp.isEmpty ? null : whatsApp,
        emailSent: emailSent,
        whatsAppShared: whatsAppOpened,
        emailMessageId: emailMessageId,
        status: AssignmentSubmissionStatus.sent,
      );
      await _repository.update(updated);
      if (!mounted) return;
      setState(() {
        _submission = updated;
        _step = _Step.receipt;
      });
    });
  }

  // -------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assignment Submission')),
      body: _submission == null
          ? const Center(child: CircularProgressIndicator())
          : _busy
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      if (_busyMessage != null) ...[const SizedBox(height: 12), Text(_busyMessage!)],
                    ],
                  ),
                )
              : switch (_step) {
                  _Step.cover => _buildCoverStep(),
                  _Step.body => _buildBodyStep(),
                  _Step.referenceSystem => _buildReferenceSystemStep(),
                  _Step.references => _buildReferencesStep(),
                  _Step.review => _buildReviewStep(),
                  _Step.transmit => _buildTransmitStep(),
                  _Step.receipt => _buildReceiptStep(),
                },
      // The primary "Continue"-style button lives in a small fixed bar
      // pinned above the keyboard/bottom edge (2026-09-02), not as the
      // last item in each step's scrolling list — a real complaint on a
      // long list of segment fields: the button could end up scrolled out
      // of view or hidden behind the keyboard. `resizeToAvoidBottomInset`
      // (Scaffold's default) keeps this bar above the keyboard
      // automatically. Compact (36px) and padded off the physical bottom
      // edge, rather than the previous full-size button glued to it.
      bottomNavigationBar: _submission == null || _busy ? null : _bottomBar(_primaryActionFor(_step)),
    );
  }

  /// The current step's one primary action, or null on steps that don't
  /// have one yet (e.g. "Cover Page"/"Main Body" before anything's been
  /// captured — those keep an inline capture button only).
  Widget? _primaryActionFor(_Step step) {
    switch (step) {
      case _Step.cover:
        return _submission!.coverPhotoFileName == null
            ? null
            : FilledButton(onPressed: _confirmCoverFields, child: const Text('Continue to Main Body'));
      case _Step.body:
        return _bodyBlocks.isEmpty ? null : FilledButton(onPressed: _confirmBody, child: const Text('Continue to References'));
      case _Step.referenceSystem:
        return FilledButton(onPressed: () => _chooseReferenceSystem(_referenceSystem), child: const Text('Continue'));
      case _Step.references:
        return _referenceEntries.isEmpty ? null : FilledButton(onPressed: _confirmReferences, child: const Text('Continue'));
      case _Step.review:
        return FilledButton.icon(
          onPressed: _consolidate,
          icon: const Icon(Icons.description_outlined, size: 18),
          label: const Text('Generate Submission'),
        );
      case _Step.transmit:
        return FilledButton.icon(
          onPressed: _send,
          icon: const Icon(Icons.send_outlined, size: 18),
          label: const Text('Send Submission'),
        );
      case _Step.receipt:
        return null;
    }
  }

  Widget? _bottomBar(Widget? action) {
    if (action == null) return null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: SizedBox(
          height: 36,
          child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 13), child: action),
        ),
      ),
    );
  }

  Widget _buildCoverStep() {
    final hasCover = _submission!.coverPhotoFileName != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Stage 1 — Cover Page', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Photograph your handwritten cover page. We\'ll read it and fill in the fields below — check and correct anything misread.'),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _captureCoverPage,
          icon: const Icon(Icons.camera_alt_outlined),
          label: Text(hasCover ? 'Retake Cover Page' : 'Capture Cover Page'),
        ),
        const SizedBox(height: 16),
        if (hasCover) ...[
          _textField('Student Name', _studentNameController),
          _textField('ID / Registration Number', _idNumberController),
          _textField('Course', _courseController),
          _textField('Subject', _subjectController),
          _textField('Assignment Title', _titleController),
          _textField('Lecturer / Teacher Name', _teacherNameController),
          _textField('Date', _dateController),
          _textField('Institution', _institutionController),
        ],
      ],
    );
  }

  Widget _buildBodyStep() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Stage 2 — Main Body', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Photograph the Introduction, Main Body, and Conclusion pages. We transcribe your work exactly as written — nothing corrected or added.'),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _captureBody,
          icon: const Icon(Icons.camera_alt_outlined),
          label: Text(_bodyBlocks.isEmpty ? 'Capture Main Body' : 'Recapture Main Body'),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < _bodyBlocks.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(
              controller: _bodyControllers[i],
              maxLines: null,
              decoration: InputDecoration(labelText: _bodyBlocks[i].type.name, border: const OutlineInputBorder()),
            ),
          ),
      ],
    );
  }

  Widget _buildReferenceSystemStep() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Stage 3 — Reference System', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('What reference system are you using?'),
        const SizedBox(height: 12),
        for (final system in ReferenceSystem.values)
          RadioListTile<ReferenceSystem>(
            value: system,
            groupValue: _referenceSystem,
            title: Text(system.label),
            onChanged: (value) => setState(() => _referenceSystem = value!),
          ),
      ],
    );
  }

  Widget _buildReferencesStep() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Stage 4 — Reference Page', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('Photograph your reference/bibliography page (${_referenceSystem.label}). Formatting is preserved exactly as written — nothing corrected or completed.'),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _captureReferences,
          icon: const Icon(Icons.camera_alt_outlined),
          label: Text(_referenceEntries.isEmpty ? 'Capture Reference Page' : 'Recapture Reference Page'),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < _referenceEntries.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(
              controller: _referenceControllers[i],
              maxLines: null,
              decoration: InputDecoration(labelText: 'Entry ${i + 1}', border: const OutlineInputBorder()),
            ),
          ),
      ],
    );
  }

  Widget _buildReviewStep() {
    final submission = _submission!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Review', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(submission.assignmentTitle.isEmpty ? '(untitled assignment)' : submission.assignmentTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                Text('${submission.studentName} · ${submission.course}'),
                const SizedBox(height: 8),
                Text('${submission.transcribedBody.length} body block(s) transcribed'),
                Text(submission.referenceSystem == ReferenceSystem.none
                    ? 'No reference page'
                    : '${submission.transcribedReferences.length} reference(s), ${submission.referenceSystem.label}'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTransmitStep() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Stage 8 — Send', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Send by email, WhatsApp, or both — each is optional, but you need at least one. Email sends '
          'automatically; WhatsApp opens the chat with your file ready to attach, one tap to send.',
        ),
        const SizedBox(height: 16),
        _textField('Lecturer / Teacher Email (optional)', _emailController, keyboardType: TextInputType.emailAddress),
        _textField('Lecturer / Teacher WhatsApp Number (optional)', _whatsAppController, keyboardType: TextInputType.phone),
      ],
    );
  }

  Widget _buildReceiptStep() {
    final submission = _submission!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 48),
        const SizedBox(height: 8),
        Text('Submission Complete', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('Screenshot this page as your proof of submission.'),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _receiptRow('Student', submission.studentName),
                _receiptRow('Assignment', submission.assignmentTitle),
                _receiptRow('Submitted', submission.submittedAt?.toLocal().toString() ?? ''),
                _receiptRow('SHA-256', submission.sha256Hash ?? ''),
                if (submission.teacherEmail != null && submission.emailSent)
                  _receiptRow('Emailed to', submission.teacherEmail!),
                if (submission.emailMessageId != null && submission.emailMessageId!.isNotEmpty)
                  _receiptRow('Email message ID', submission.emailMessageId!),
                if (submission.teacherWhatsApp != null && submission.whatsAppShared)
                  _receiptRow('Shared to (WhatsApp)', submission.teacherWhatsApp!),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // "Make the same sent copy after sending available to the sender/
        // student" (2026-09-02) — only offered here, after a real send,
        // never earlier: there's no share/download action anywhere before
        // this receipt step, so nothing lets a student grab the processed
        // work before it's actually been submitted to the teacher.
        OutlinedButton.icon(
          onPressed: _saveOwnCopy,
          icon: const Icon(Icons.download_outlined),
          label: const Text('Save / Share Your Copy'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ],
    );
  }

  Future<void> _saveOwnCopy() async {
    final submission = _submission!;
    final dir = await _repository.submissionDir(submission);
    final docFile = _repository.fileFor(submission, dir, submission.docFileName!);
    final bundleFile = _repository.fileFor(submission, dir, submission.imageBundleFileName!);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(docFile.path), XFile(bundleFile.path)],
        subject: 'Your copy — ${submission.assignmentTitle.isEmpty ? submission.studentName : submission.assignmentTitle}',
        text: 'This is the same copy that was sent to your teacher — save it to your files or another app.',
      ),
    );
  }

  Widget _receiptRow(String label, String value) => Padding(
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

  Widget _textField(String label, TextEditingController controller, {TextInputType? keyboardType}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: controller,
          keyboardType: keyboardType,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );
}
