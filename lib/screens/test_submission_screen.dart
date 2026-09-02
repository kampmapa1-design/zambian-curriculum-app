import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/marking_script.dart';
import '../models/teacher_submission.dart';
import '../models/test_submission.dart';
import '../services/assignment_submission_email_service.dart';
import '../services/marking_script_repository.dart';
import '../services/rewarded_ad_service.dart';
import '../services/teacher_dashboard_service.dart';
import '../services/test_submission_document_service.dart';
import '../services/test_submission_repository.dart';
import '../services/test_submission_transcription_service.dart';
import 'document_pages_capture_screen.dart';
import 'marking_queue_screen.dart';

/// Whether Test Submission's rewarded-ad gate is active — Stage 9's
/// dormant scaffold, off by default so the feature is fully free during
/// testing. Same single-toggle pattern as
/// `kAssignmentSubmissionAdGateEnabled`, deliberately its own flag rather
/// than sharing that one, in case the two features are ever turned on at
/// different times.
const bool kTestSubmissionAdGateEnabled = false;

enum _Step { capture, info, review, transmit, receipt }

/// Test Submission — a student photographs up to 5 pages of a handwritten
/// test, the app detects and tags each answer segment by its handwritten
/// question-number marker (never guessing when no marker is found),
/// consolidates everything into one Word document plus a viewable PDF
/// backup of every original photo (2026-09-02: was a PDF + a .zip; now a
/// Word doc + a PDF, per explicit request), records a SHA-256 + timestamp
/// as proof, and sends the
/// result to a teacher by email (automatic) and/or WhatsApp (one tap) —
/// reusing Assignment Submission's transmission logic exactly. A finished
/// submission can also be sent straight into the AI Marking queue
/// (Stage 10) without recapturing anything.
class TestSubmissionScreen extends StatefulWidget {
  const TestSubmissionScreen({
    super.key,
    this.repository,
    this.transcriptionService,
    this.documentService,
    this.emailService,
    this.markingScriptRepository,
    this.dashboardService,
  });

  final TestSubmissionRepository? repository;
  final TestSubmissionTranscriptionService? transcriptionService;
  final TestSubmissionDocumentService? documentService;
  final AssignmentSubmissionEmailService? emailService;
  final MarkingScriptRepository? markingScriptRepository;
  final TeacherDashboardService? dashboardService;

  @override
  State<TestSubmissionScreen> createState() => _TestSubmissionScreenState();
}

class _TestSubmissionScreenState extends State<TestSubmissionScreen> {
  late final TestSubmissionRepository _repository = widget.repository ?? TestSubmissionRepository();
  late final TestSubmissionTranscriptionService _transcriptionService =
      widget.transcriptionService ?? TestSubmissionTranscriptionService();
  late final TestSubmissionDocumentService _documentService = widget.documentService ?? TestSubmissionDocumentService();
  late final AssignmentSubmissionEmailService _emailService = widget.emailService ?? AssignmentSubmissionEmailService();
  late final MarkingScriptRepository _markingScriptRepository =
      widget.markingScriptRepository ?? MarkingScriptRepository();
  late final TeacherDashboardService _dashboardService = widget.dashboardService ?? TeacherDashboardService();

  TestSubmission? _submission;
  _Step _step = _Step.capture;
  bool _busy = false;
  String? _busyMessage;

  final _studentNameController = TextEditingController();
  final _subjectController = TextEditingController();
  final _gradeController = TextEditingController();
  final _institutionController = TextEditingController();
  final _testNameController = TextEditingController();

  final _emailController = TextEditingController();
  final _whatsAppController = TextEditingController();

  List<TestAnswerSegment> _segments = [];
  final List<TextEditingController> _questionControllers = [];
  final List<TextEditingController> _textControllers = [];

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
    // matches Chief Marker's own capture screen (ScriptBatchCaptureScreen:
    // "the camera opens immediately... no picker screens gate it"). Who
    // this test is for is asked right after the first real capture, not
    // before — same reasoning: a real capture already in hand is a better
    // moment to ask than an empty form before the student has done
    // anything. Backing out empty-handed still leaves the ordinary manual
    // "Capture Pages" button as a retry path — this call doesn't loop.
    await _capturePages();
  }

  @override
  void dispose() {
    _studentNameController.dispose();
    _subjectController.dispose();
    _gradeController.dispose();
    _institutionController.dispose();
    _testNameController.dispose();
    _emailController.dispose();
    _whatsAppController.dispose();
    for (final c in [..._questionControllers, ..._textControllers]) {
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
  // Stage 1 — Who is this for. Asked AFTER the first capture (2026-09-02),
  // not before — see _init()'s doc comment for why. Plain typed fields
  // only (2026-09-02) — this used to push a full curriculum subject/
  // grade picker screen; removed per explicit request ("remove the page
  // about the list of subjects"), replaced with Subject/Course and
  // School/Institution as free text right on this same page, alongside
  // Student Name. Grade/Class is kept as a third free-text field (not
  // explicitly requested, but needed: MarkingScript.gradeName, used by
  // the Stage 10 "Send to Marking" bridge, has nowhere else to come from
  // once the picker is gone).
  // -------------------------------------------------------------------

  void _confirmInfo() {
    final name = _studentNameController.text.trim();
    final subject = _subjectController.text.trim();
    if (name.isEmpty || subject.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the student\'s name and subject/course to continue.')),
      );
      return;
    }
    final updated = _submission!.copyWith(
      studentName: name,
      subjectName: subject,
      gradeName: _gradeController.text.trim(),
      institution: _institutionController.text.trim(),
      testName: _testNameController.text.trim(),
    );
    _repository.update(updated);
    setState(() {
      _submission = updated;
      _step = _Step.review;
    });
  }

  // -------------------------------------------------------------------
  // Stage 2-3 — Capture (capped at 5 pages) + question-tagged transcription.
  // Runs FIRST, launched automatically by _init() — the camera opens with
  // nothing gating it, same as Chief Marker's own capture flow.
  // -------------------------------------------------------------------

  Future<void> _capturePages() async {
    final pages = await Navigator.of(context).push<List<File>?>(
      MaterialPageRoute(
        builder: (_) => const DocumentPagesCaptureScreen(
          title: 'Test Pages',
          instructions: 'Photograph up to 5 pages of your test answers, in order, then tap Done.',
          maxPages: 5,
        ),
      ),
    );
    if (pages == null || pages.isEmpty || !mounted) return;

    await _runBusy('Reading your answers…', () async {
      final submission = _submission!;
      final fileNames = <String>[];
      for (var i = 0; i < pages.length; i++) {
        fileNames.add(await _repository.storeFile(submission, pages[i], 'page_${(i + 1).toString().padLeft(2, '0')}.jpg'));
      }
      var updated = submission.copyWith(pageFileNames: fileNames);
      await _repository.update(updated);
      setState(() => _submission = updated);

      final transcribed = await _transcriptionService.transcribe(pages);
      updated = updated.copyWith(segments: transcribed.segments);
      await _repository.update(updated);
      if (!mounted) return;
      setState(() {
        _submission = updated;
        _segments = transcribed.segments;
        for (final c in [..._questionControllers, ..._textControllers]) {
          c.dispose();
        }
        _questionControllers
          ..clear()
          ..addAll([for (final s in transcribed.segments) TextEditingController(text: s.questionNumber)]);
        _textControllers
          ..clear()
          ..addAll([for (final s in transcribed.segments) TextEditingController(text: s.text)]);
      });
      if (transcribed.notes.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Double-check: ${transcribed.notes}')));
      }
    });
  }

  void _confirmSegments() {
    final edited = [
      for (var i = 0; i < _segments.length; i++)
        TestAnswerSegment(questionNumber: _questionControllers[i].text.trim(), text: _textControllers[i].text),
    ];
    setState(() {
      _segments = edited;
      _submission = _submission!.copyWith(segments: edited);
      _step = _Step.info;
    });
    _repository.update(_submission!);
  }

  // -------------------------------------------------------------------
  // Stage 4-6 — Consolidate
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
        status: TestSubmissionStatus.consolidated,
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

  /// Stage 9 — dormant by default (see [kTestSubmissionAdGateEnabled]).
  Future<void> _maybeShowAd() async {
    if (!kTestSubmissionAdGateEnabled) return;
    await RewardedAdService.instance.showAd();
  }

  // -------------------------------------------------------------------
  // Stage 7 — Transmission (reuses Assignment Submission's logic exactly)
  // -------------------------------------------------------------------

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
      final subject = 'Test Submission — ${submission.subjectName.isEmpty ? submission.studentName : submission.subjectName}';

      var emailSent = false;
      String? emailMessageId;
      if (email.isNotEmpty) {
        try {
          emailMessageId = await _emailService.send(
            recipientEmail: email,
            studentName: submission.studentName,
            assignmentTitle: submission.subjectName,
            submissionHash: submission.sha256Hash ?? '',
            submittedAt: submission.submittedAt ?? DateTime.now(),
            attachments: [
              EmailAttachmentFile(file: docFile, filename: submission.docFileName!),
              EmailAttachmentFile(file: bundleFile, filename: submission.imageBundleFileName!),
            ],
            submissionKind: 'test',
          );
          emailSent = true;
        } on AssignmentSubmissionEmailUnavailable catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Email not sent: $e')));
          }
        }

        // Teacher Submissions Dashboard (Stage 11, 2026-09-02) — best
        // effort, never blocks or surfaces an error on top of the actual
        // send above: the teacher's email is the only thing that ties a
        // submission to a Dashboard mailbox, so this only fires when one
        // was entered, independent of whether the transactional email
        // itself succeeded.
        try {
          await _dashboardService.submitToDashboard(
            teacherEmail: email,
            kind: SubmissionKind.test,
            studentName: submission.studentName,
            className: submission.gradeName,
            subjectName: submission.subjectName,
            title: submission.testName.isEmpty ? submission.subjectName : submission.testName,
            submittedAt: submission.submittedAt ?? DateTime.now(),
            sha256Hash: submission.sha256Hash ?? '',
            referenceInfo: submission.segments.map((s) => s.questionNumber).join(', '),
            attachments: [
              DashboardUploadFile(
                file: docFile,
                filename: submission.docFileName!,
                contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              ),
              DashboardUploadFile(file: bundleFile, filename: submission.imageBundleFileName!, contentType: 'application/pdf'),
            ],
          );
        } catch (_) {
          // Silently ignored by design — see the comment above.
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

      if (!emailSent && !whatsAppOpened) return;

      final updated = submission.copyWith(
        teacherEmail: email.isEmpty ? null : email,
        teacherWhatsApp: whatsApp.isEmpty ? null : whatsApp,
        emailSent: emailSent,
        whatsAppShared: whatsAppOpened,
        emailMessageId: emailMessageId,
        status: TestSubmissionStatus.sent,
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
  // Stage 10 — Send to Marking (dormant convenience, not part of the
  // 9-stage spec proper): turns this same submission's already-captured
  // images straight into a ready-to-grade MarkingScript, carrying Stage
  // 3's question-number segmentation along as a grading hint — no
  // recapture, no re-upload, no re-typing name/subject/grade.
  // -------------------------------------------------------------------

  Future<CandidateGender?> _askGender() {
    CandidateGender? gender;
    return showDialog<CandidateGender>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Student\'s gender'),
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

  Future<void> _sendToMarking() async {
    final gender = await _askGender();
    if (gender == null || !mounted) return;

    await _runBusy('Adding to Marking queue…', () async {
      final submission = _submission!;
      final pageFiles = await _repository.pageFilesFor(submission, submission.pageFileNames);

      final nameParts = submission.studentName.trim().split(RegExp(r'\s+'));
      final firstName = nameParts.first;
      final surname = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';

      final nextNumber = await _markingScriptRepository.nextScriptNumber();
      final script = await _markingScriptRepository.saveScript(
        firstName: firstName,
        surname: surname,
        gender: gender,
        scriptNumber: nextNumber,
        subjectName: submission.subjectName,
        gradeName: submission.gradeName,
        capturedPageFiles: pageFiles,
        preSegmentedAnswers: [
          for (final s in submission.segments) PreSegmentedAnswer(questionNumber: s.questionNumber, text: s.text),
        ],
      );

      final updated = submission.copyWith(markingScriptId: script.id);
      await _repository.update(updated);
      if (!mounted) return;
      setState(() => _submission = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added to Marking queue as script #${script.scriptNumber} — pick a marking key there when ready to grade.')),
      );
    });
  }

  // -------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Test Submission')),
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
                  _Step.info => _buildInfoStep(),
                  _Step.capture => _buildCaptureStep(),
                  _Step.review => _buildReviewStep(),
                  _Step.transmit => _buildTransmitStep(),
                  _Step.receipt => _buildReceiptStep(),
                },
      // Primary action pinned in a small fixed bar above the keyboard/
      // bottom edge (2026-09-02), not as the last item in a scrolling
      // list — was getting scrolled out of view or hidden behind the
      // keyboard on a long segment list. See AssignmentSubmissionScreen's
      // identical fix for the full reasoning.
      bottomNavigationBar: _submission == null || _busy ? null : _bottomBar(_primaryActionFor(_step)),
    );
  }

  Widget? _primaryActionFor(_Step step) {
    switch (step) {
      case _Step.info:
        return FilledButton(onPressed: _confirmInfo, child: const Text('Continue to Review'));
      case _Step.capture:
        return _segments.isEmpty ? null : FilledButton(onPressed: _confirmSegments, child: const Text('Continue'));
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

  Widget _buildInfoStep() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Who is this for?', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Enter the student\'s name, subject/course, and school.'),
        const SizedBox(height: 16),
        _textField('Student Name', _studentNameController),
        _textField('Subject / Course', _subjectController),
        _textField('Grade / Class (optional)', _gradeController),
        _textField('School / Institution (optional)', _institutionController),
        _textField('Test Name (optional, e.g. "Mid-Term Test 1")', _testNameController),
      ],
    );
  }

  Widget _buildCaptureStep() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Capture Pages', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          _segments.isEmpty
              ? 'Opening the camera — photograph up to 5 pages of the test answers, in order, then tap Done.'
              : 'We detect each handwritten question number and tag the matching answer — segments with no '
                  'clear marker are tagged "Unlabeled" rather than guessed. Check and correct anything below.',
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _capturePages,
          icon: const Icon(Icons.camera_alt_outlined),
          label: Text(_segments.isEmpty ? 'Capture Pages (up to 5)' : 'Recapture Pages'),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < _segments.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _questionControllers[i],
                    decoration: const InputDecoration(labelText: 'Question #', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _textControllers[i],
                  maxLines: null,
                  decoration: const InputDecoration(labelText: 'Answer', border: OutlineInputBorder()),
                ),
              ],
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
                Text(submission.subjectName.isEmpty ? '(no subject entered)' : submission.subjectName,
                    style: Theme.of(context).textTheme.titleMedium),
                Text([submission.studentName, submission.gradeName, submission.institution]
                    .where((s) => s.isNotEmpty)
                    .join(' · ')),
                const SizedBox(height: 8),
                Text('${submission.segments.length} answer segment(s) transcribed'),
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
        Text('Stage 7 — Send', style: Theme.of(context).textTheme.titleLarge),
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
                if (submission.institution.isNotEmpty) _receiptRow('School / Institution', submission.institution),
                _receiptRow('Subject', submission.subjectName),
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
        if (submission.markingScriptId == null)
          OutlinedButton.icon(
            onPressed: _sendToMarking,
            icon: const Icon(Icons.rule_folder_outlined),
            label: const Text('Send to Marking Queue'),
          )
        else
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MarkingQueueScreen())),
            icon: const Icon(Icons.check),
            label: const Text('Already in Marking Queue — Open Queue'),
          ),
        const SizedBox(height: 12),
        // "Make the same sent copy after sending available to the sender/
        // student" (2026-09-02) — only offered here, after a real send,
        // never earlier: there's no share/download action anywhere before
        // this receipt step.
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
        subject: 'Your copy — ${submission.subjectName.isEmpty ? submission.studentName : submission.subjectName}',
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
