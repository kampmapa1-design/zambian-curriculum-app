import 'dart:io';

import 'package:document_camera_frame/document_camera_frame.dart';
import 'package:flutter/material.dart';

import '../models/marking_script.dart';
import '../models/syllabus_models.dart';
import '../services/candidate_name_detection_service.dart';
import '../services/marking_script_repository.dart';
import 'subject_grade_topic_picker_screen.dart';

/// AI-Assisted Marking, Stage 1 — burst capture. A teacher photographs one
/// student script (several pages) in a single session: enter the student's
/// details once, then capture each page in turn. Each page is
/// auto-cropped, deskewed, and contrast-enhanced on-device (ML Kit, via
/// [DocumentCameraFrame]) — no network needed. The finished set is saved
/// as one [MarkingScript], ready for later stages (batch queue, marking
/// scheme, AI grading) to pick up.
///
/// Per-page capture is a deliberate choice over a single continuous
/// hold-to-capture session: it reuses a proven crop/deskew engine rather
/// than a custom motion-detection pipeline, at the cost of a tap per page
/// instead of true hands-free capture.
class BurstCaptureScreen extends StatefulWidget {
  const BurstCaptureScreen({super.key, this.repository});

  final MarkingScriptRepository? repository;

  @override
  State<BurstCaptureScreen> createState() => _BurstCaptureScreenState();
}

class _BurstCaptureScreenState extends State<BurstCaptureScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  final CandidateNameDetectionService _nameDetectionService = CandidateNameDetectionService();

  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _surnameController = TextEditingController();
  final _idController = TextEditingController();
  final _scriptNumberController = TextEditingController();

  CandidateGender? _gender;
  SyllabusTemplate? _subjectGrade;

  bool _sessionStarted = false;
  bool _loadingNextNumber = true;
  bool _saving = false;
  bool _detectingName = false;
  final List<File> _capturedPages = [];

  @override
  void initState() {
    super.initState();
    _prefillScriptNumber();
  }

  Future<void> _prefillScriptNumber() async {
    final next = await _repository.nextScriptNumber();
    if (!mounted) return;
    setState(() {
      _scriptNumberController.text = next.toString();
      _loadingNextNumber = false;
    });
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _surnameController.dispose();
    _idController.dispose();
    _scriptNumberController.dispose();
    super.dispose();
  }

  Future<void> _pickSubjectGrade() async {
    final result = await Navigator.of(context).push<SyllabusTemplate>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(
          title: 'Subject & Grade',
          pickTopic: false,
        ),
      ),
    );
    if (result != null && mounted) setState(() => _subjectGrade = result);
  }

  void _startSession() {
    final formValid = _formKey.currentState?.validate() ?? false;
    if (!formValid) return;
    if (_gender == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select the candidate\'s gender.')),
      );
      return;
    }
    if (_subjectGrade == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select the subject and grade this script is for.')),
      );
      return;
    }
    setState(() => _sessionStarted = true);
    _captureNextPage();
  }

  Future<void> _captureNextPage() async {
    final result = await Navigator.of(context).push<DocumentCaptureData>(
      MaterialPageRoute(
        builder: (_) => DocumentCameraFrame(
          frameWidth: 320,
          frameHeight: 440,
          requireBothSides: false,
          enableAutoCapture: true,
          showCloseButton: true,
          // Stage H — meaningfully smaller files than the package's
          // default (90) while staying clear enough for both a teacher's
          // own review and AI grading; document scans hold up fine well
          // below photographic quality.
          imageQuality: 75,
          bottomHintText: 'Page ${_capturedPages.length + 1} — hold the script flat and steady',
          onDocumentSaved: (data) => Navigator.of(context).pop(data),
        ),
      ),
    );

    if (result == null || !result.hasFrontSide || result.frontImagePath == null) {
      // Teacher backed out of this page — if it's the very first page,
      // cancel the whole session; otherwise just stop adding pages so
      // whatever was already captured can still be saved.
      if (_capturedPages.isEmpty && mounted) setState(() => _sessionStarted = false);
      return;
    }

    if (!mounted) return;
    final isFirstPage = _capturedPages.isEmpty;
    setState(() => _capturedPages.add(File(result.frontImagePath!)));

    // Stage D — attempt to auto-fill the name from the first page, but
    // only if the teacher hasn't already typed something (either up
    // front, or from a previous detection attempt) — never overwrite a
    // real edit with a lower-confidence guess.
    if (isFirstPage && _firstNameController.text.trim().isEmpty && _surnameController.text.trim().isEmpty) {
      _detectNameFromFirstPage();
    }
  }

  Future<void> _detectNameFromFirstPage() async {
    if (_capturedPages.isEmpty) return;
    setState(() => _detectingName = true);
    final detected = await _nameDetectionService.detect(_capturedPages.first);
    if (!mounted) return;
    setState(() {
      _detectingName = false;
      // Still check emptiness here too — the teacher may have typed
      // something manually while detection was running.
      if (_firstNameController.text.trim().isEmpty && _surnameController.text.trim().isEmpty && !detected.isEmpty) {
        _firstNameController.text = detected.firstName;
        _surnameController.text = detected.surname;
      }
    });
  }

  Future<void> _finishAndSave() async {
    if (_capturedPages.isEmpty) return;
    if (_firstNameController.text.trim().isEmpty || _surnameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter (or correct) the candidate\'s first name and surname before saving.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final script = await _repository.saveScript(
        firstName: _firstNameController.text.trim(),
        surname: _surnameController.text.trim(),
        gender: _gender!,
        studentIdNumber: _idController.text.trim().isEmpty ? null : _idController.text.trim(),
        scriptNumber: int.parse(_scriptNumberController.text.trim()),
        subjectName: _subjectGrade!.subject.name,
        gradeName: _subjectGrade!.grade.name,
        capturedPageFiles: _capturedPages,
      );
      if (!mounted) return;
      Navigator.of(context).pop<MarkingScript>(script);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save this script: $error')),
      );
      setState(() => _saving = false);
    }
  }

  void _removePage(int index) {
    setState(() => _capturedPages.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Capture Student Script')),
      body: _sessionStarted ? _buildCaptureSession(context) : _buildDetailsForm(context),
    );
  }

  Widget _buildDetailsForm(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Whose script is this?', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              "Enter the student's details now, or leave the name blank — it can also be auto-filled "
              'from the first captured page, and edited either way before saving.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            // First name on top, surname below — matches the order the
            // candidate's name is displayed everywhere else in this
            // feature (queue list, review screen, marksheet). Optional
            // here (not validated) since auto-detect can fill these in
            // after the first page is captured.
            TextFormField(
              controller: _firstNameController,
              decoration: const InputDecoration(
                labelText: 'First name (optional — can auto-fill)',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _surnameController,
              decoration: const InputDecoration(
                labelText: 'Surname (optional — can auto-fill)',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            Text('Gender', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            SegmentedButton<CandidateGender>(
              segments: const [
                ButtonSegment(value: CandidateGender.male, label: Text('Male')),
                ButtonSegment(value: CandidateGender.female, label: Text('Female')),
              ],
              selected: {if (_gender != null) _gender!},
              emptySelectionAllowed: true,
              onSelectionChanged: (selection) => setState(() => _gender = selection.firstOrNull),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickSubjectGrade,
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Subject & grade', border: OutlineInputBorder()),
                child: Text(
                  _subjectGrade == null
                      ? 'Tap to select'
                      : '${_subjectGrade!.subject.name} · ${_subjectGrade!.grade.name}',
                  style: _subjectGrade == null
                      ? TextStyle(color: Theme.of(context).colorScheme.outline)
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _idController,
              decoration: const InputDecoration(
                labelText: 'Student ID (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _scriptNumberController,
              enabled: !_loadingNextNumber,
              decoration: InputDecoration(
                labelText: 'Script number',
                border: const OutlineInputBorder(),
                suffixIcon: _loadingNextNumber
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : null,
              ),
              keyboardType: TextInputType.number,
              validator: (v) => (v == null || int.tryParse(v.trim()) == null) ? 'Enter a number' : null,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loadingNextNumber ? null : _startSession,
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Start Capturing Pages'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureSession(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Editable here too, not just on the details form — this is
              // where an AI-detected name (or a blank left for it) first
              // becomes visible, so correcting it should be possible right
              // here without navigating back.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _firstNameController,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'First name',
                              border: OutlineInputBorder(),
                            ),
                            textCapitalization: TextCapitalization.words,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        if (_detectingName) ...[
                          const SizedBox(width: 8),
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _surnameController,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Surname',
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Script ${_scriptNumberController.text.trim()}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Chip(label: Text('${_capturedPages.length} page(s)')),
            ],
          ),
        ),
        Expanded(
          child: _capturedPages.isEmpty
              ? const Center(child: Text('No pages captured yet.'))
              : GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.75,
                  ),
                  itemCount: _capturedPages.length,
                  itemBuilder: (context, index) => Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(_capturedPages[index], fit: BoxFit.cover),
                      ),
                      Positioned(
                        top: 4,
                        left: 4,
                        child: CircleAvatar(
                          radius: 12,
                          backgroundColor: Colors.black54,
                          child: Text('${index + 1}', style: const TextStyle(fontSize: 12, color: Colors.white)),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                          onPressed: _saving ? null : () => _removePage(index),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _captureNextPage,
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: const Text('Capture Next Page'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_saving || _capturedPages.isEmpty) ? null : _finishAndSave,
                  icon: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: Text(_saving ? 'Saving…' : 'Finish & Save'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
