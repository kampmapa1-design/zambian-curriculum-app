import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/generated_report_form.dart';
import '../models/report_class.dart';
import '../services/generated_report_form_repository.dart';
import '../services/head_teacher_signature_service.dart';
import '../services/report_class_repository.dart';
import '../services/report_form_document_service.dart';

/// Report Form Pipeline, Stage 12 — "Approve & Sign". First use on a
/// device sets up a local password + stores a real signature image (see
/// HeadTeacherSignatureService's own doc comment on what "password-
/// protected" means here — a local device gate, not a real account
/// system). Every later approval only asks for the password again; on
/// success, every report passed in gets re-generated with the signature
/// image embedded and marked signed — the signature is never shown or
/// used anywhere in this app without that password re-entry succeeding
/// for that specific approval action.
class HeadTeacherApprovalScreen extends StatefulWidget {
  const HeadTeacherApprovalScreen({
    super.key,
    required this.reportClass,
    required this.reportsToSign,
    this.repository,
    this.reportFormRepository,
    this.signatureService,
    this.documentService,
  });

  final ReportClass reportClass;
  final List<GeneratedReportForm> reportsToSign;
  final ReportClassRepository? repository;
  final GeneratedReportFormRepository? reportFormRepository;
  final HeadTeacherSignatureService? signatureService;
  final ReportFormDocumentService? documentService;

  @override
  State<HeadTeacherApprovalScreen> createState() => _HeadTeacherApprovalScreenState();
}

class _HeadTeacherApprovalScreenState extends State<HeadTeacherApprovalScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  late final GeneratedReportFormRepository _reportFormRepository =
      widget.reportFormRepository ?? GeneratedReportFormRepository();
  late final HeadTeacherSignatureService _signatureService = widget.signatureService ?? HeadTeacherSignatureService();
  late final ReportFormDocumentService _documentService = widget.documentService ?? ReportFormDocumentService();

  bool? _isSetUp;
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nameController = TextEditingController();
  File? _signatureImage;
  bool _busy = false;
  String? _error;
  String _progressText = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final setUp = await _signatureService.isSetUp();
    if (!mounted) return;
    setState(() => _isSetUp = setUp);
  }

  Future<void> _pickSignatureImage() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png']);
    if (result.isEmpty || !mounted) return;
    setState(() => _signatureImage = File(result.single.path!));
  }

  Future<void> _completeSetup() async {
    if (_nameController.text.trim().isEmpty ||
        _passwordController.text.isEmpty ||
        _passwordController.text != _confirmPasswordController.text ||
        _signatureImage == null) {
      setState(() => _error = 'Fill in a name, a matching password in both fields, and a signature image.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await _signatureService.setup(
      password: _passwordController.text,
      signatureImageBytes: await _signatureImage!.readAsBytes(),
      signedByName: _nameController.text.trim(),
    );
    _passwordController.clear();
    if (!mounted) return;
    setState(() {
      _isSetUp = true;
      _busy = false;
    });
  }

  Future<void> _approveAndSign() async {
    if (_passwordController.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final valid = await _signatureService.verifyPassword(_passwordController.text);
    if (!valid) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Incorrect password.';
      });
      return;
    }

    final signatureBytes = await _signatureService.signatureImageBytes();
    final signedByName = await _signatureService.signedByName() ?? '';
    if (signatureBytes == null) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'No signature image on file — set up again.';
      });
      return;
    }

    final subjects = await _repository.listSubjects(widget.reportClass.id);
    final positions = await _repository.classPositions(widget.reportClass.id);
    final classSize =
        (await _repository.aggregateScores(widget.reportClass.id)).values.where((v) => v != null).length;
    final learners = await _repository.listLearners(widget.reportClass.id);
    final learnersById = {for (final l in learners) l.id: l};

    var done = 0;
    for (final report in widget.reportsToSign) {
      if (!mounted) return;
      setState(() => _progressText = 'Signing ${report.learnerName} (${done + 1} of ${widget.reportsToSign.length})…');

      final learner = learnersById[report.learnerId];
      if (learner == null) {
        done++;
        continue;
      }
      final scores = <int, double?>{};
      final comments = <int, String?>{};
      for (final subject in subjects) {
        scores[subject.id] = await _repository.scoreFor(learner.id, subject, allSubjects: subjects);
        comments[subject.id] = (await _repository.getScore(learner.id, subject.id))?.comment;
      }
      final data = ReportFormMailMergeData(
        reportClass: widget.reportClass,
        learner: learner,
        subjects: subjects,
        scores: scores,
        comments: comments,
        classPosition: positions[learner.id],
        classSize: classSize,
      );
      final signedBytes = _documentService.generateForLearner(
        data,
        signatureImageBytes: signatureBytes,
        signedByName: signedByName,
      );
      await _reportFormRepository.markSigned(report: report, signedDocxBytes: signedBytes, signedByName: signedByName);
      done++;
    }

    _passwordController.clear();
    if (!mounted) return;
    Navigator.of(context).pop(done);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Approve & Sign')),
      body: _isSetUp == null
          ? const Center(child: CircularProgressIndicator())
          : _busy
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(_progressText.isEmpty ? 'Working…' : _progressText),
                    ],
                  ),
                )
              : _isSetUp!
                  ? _buildApprove(context)
                  : _buildSetup(context),
    );
  }

  Widget _buildSetup(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('First time here — set up your name, a local password, and your signature image. '
            'The password will be asked again every time you approve a batch of reports.'),
        const SizedBox(height: 16),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: 'Your name (e.g. "Mrs. Banda, Head Teacher")', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          decoration: const InputDecoration(labelText: 'Set a password', border: OutlineInputBorder()),
          obscureText: true,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirmPasswordController,
          decoration: const InputDecoration(labelText: 'Confirm password', border: OutlineInputBorder()),
          obscureText: true,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _pickSignatureImage,
          icon: const Icon(Icons.draw_outlined),
          label: Text(_signatureImage == null ? 'Upload Signature Image' : 'Signature image selected'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton(onPressed: _completeSetup, child: const Text('Save & Continue')),
      ],
    );
  }

  Widget _buildApprove(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Approve ${widget.reportsToSign.length} report form(s) for ${widget.reportClass.classGrade}.'),
        const SizedBox(height: 16),
        TextField(
          controller: _passwordController,
          decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
          obscureText: true,
          onSubmitted: (_) => _approveAndSign(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _approveAndSign,
          icon: const Icon(Icons.verified_outlined),
          label: const Text('Approve & Sign'),
        ),
      ],
    );
  }
}
