import 'dart:io';

import 'package:document_camera_frame/document_camera_frame.dart';
import 'package:flutter/material.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../models/syllabus_models.dart';
import '../services/batch_grading_runner.dart';
import '../services/candidate_name_detection_service.dart';
import '../services/marking_grading_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import 'subject_grade_topic_picker_screen.dart';

/// AI-Assisted Marking — continuous batch capture for a whole stack of
/// scripts in one uninterrupted camera session, instead of the one-
/// script-at-a-time flow in BurstCaptureScreen. A teacher captures pages,
/// taps "Script Completed" whenever one candidate's script ends and the
/// next begins, and taps "Complete Session" when the whole stack is done
/// — nothing is sent anywhere until they then explicitly confirm "Mark
/// all scripts?", matching this feature's offline-until-confirmed
/// requirement exactly (entirely on-device up to that one point).
///
/// Subject/grade and the marking scheme to grade against are picked once,
/// up front, for the whole session — re-asking per script would defeat
/// the point of a continuous flow. Candidate names are auto-detected per
/// script (see CandidateNameDetectionService), same convenience/never-
/// blocking behavior as BurstCaptureScreen; gender is NOT asked during
/// capture (would require stopping for every single script) — every
/// script this screen creates is saved with
/// MarkingScript.genderConfirmed: false, and MarkingReviewScreen requires
/// a teacher to confirm it before a script can be finalized.
class ScriptBatchCaptureScreen extends StatefulWidget {
  const ScriptBatchCaptureScreen({
    super.key,
    this.repository,
    this.schemeRepository,
    this.gradingService,
    this.nameDetectionService,
  });

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;
  final MarkingGradingService? gradingService;
  final CandidateNameDetectionService? nameDetectionService;

  @override
  State<ScriptBatchCaptureScreen> createState() => _ScriptBatchCaptureScreenState();
}

class _ScriptBatchCaptureScreenState extends State<ScriptBatchCaptureScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final MarkingGradingService _gradingService = widget.gradingService ?? MarkingGradingService();
  late final CandidateNameDetectionService _nameDetectionService =
      widget.nameDetectionService ?? CandidateNameDetectionService();

  bool _settingUp = true;
  SyllabusTemplate? _subjectGrade;
  MarkingScheme? _scheme;
  int _nextScriptNumber = 1;

  final List<File> _currentScriptPages = [];
  String _detectedFirstName = '';
  String _detectedSurname = '';
  bool _detectingName = false;

  final List<MarkingScript> _finalizedScripts = [];
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setUp());
  }

  Future<void> _setUp() async {
    final template = await Navigator.of(context).push<SyllabusTemplate>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Subject & Grade for This Batch', pickTopic: false),
      ),
    );
    if (!mounted) return;
    if (template == null) {
      Navigator.of(context).pop();
      return;
    }

    final schemes = await _schemeRepository.loadCatalog();
    if (!mounted) return;
    if (schemes.schemes.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('No marking scheme yet'),
          content: const Text(
            'This batch needs a marking key to grade against. Upload or build one first, then start this batch again.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK'))],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }

    final scheme = await showDialog<MarkingScheme>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Which marking key is this batch for?'),
        children: [
          for (final s in schemes.schemes)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(s),
              child: Text('${s.title} (${s.questions.length} question(s))'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (scheme == null) {
      Navigator.of(context).pop();
      return;
    }

    final nextNumber = await _repository.nextScriptNumber();
    if (!mounted) return;
    setState(() {
      _subjectGrade = template;
      _scheme = scheme;
      _nextScriptNumber = nextNumber;
      _settingUp = false;
    });
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
          imageQuality: 75,
          bottomHintText: _currentScriptPages.isEmpty
              ? 'New script — page 1 (scripts typically run around 6 pages; tap "Script Completed" whenever this one ends)'
              : 'Page ${_currentScriptPages.length + 1} of this script',
          onDocumentSaved: (data) => Navigator.of(context).pop(data),
        ),
      ),
    );

    if (!mounted) return;
    if (result == null || !result.hasFrontSide || result.frontImagePath == null) {
      // Backed out of a page — if nothing at all has been captured yet
      // (no pages, no finalized scripts), there's nothing to salvage.
      if (_currentScriptPages.isEmpty && _finalizedScripts.isEmpty) Navigator.of(context).pop();
      return;
    }

    final isFirstPageOfScript = _currentScriptPages.isEmpty;
    setState(() => _currentScriptPages.add(File(result.frontImagePath!)));

    if (isFirstPageOfScript) _detectNameForCurrentScript();
  }

  Future<void> _detectNameForCurrentScript() async {
    if (_currentScriptPages.isEmpty) return;
    setState(() => _detectingName = true);
    final detected = await _nameDetectionService.detect(_currentScriptPages.first);
    if (!mounted) return;
    setState(() {
      _detectingName = false;
      _detectedFirstName = detected.firstName;
      _detectedSurname = detected.surname;
    });
  }

  /// Finalizes the in-progress script (if it has any pages) as one saved
  /// [MarkingScript] — genderConfirmed: false throughout, since this
  /// continuous flow never stops to ask; linked to the scheme picked at
  /// the start of the session so it's ready to grade once "Mark all
  /// scripts?" is confirmed.
  Future<void> _finalizeCurrentScript() async {
    if (_currentScriptPages.isEmpty) return;
    final script = await _repository.saveScript(
      firstName: _detectedFirstName,
      surname: _detectedSurname,
      gender: CandidateGender.male,
      scriptNumber: _nextScriptNumber,
      subjectName: _subjectGrade!.subject.name,
      gradeName: _subjectGrade!.grade.name,
      capturedPageFiles: _currentScriptPages,
    );
    final linked = script.copyWith(schemeId: _scheme!.id, genderConfirmed: false);
    await _repository.update(linked);

    setState(() {
      _finalizedScripts.add(linked);
      _currentScriptPages.clear();
      _detectedFirstName = '';
      _detectedSurname = '';
      _nextScriptNumber++;
    });
  }

  Future<void> _onScriptCompleted() async {
    await _finalizeCurrentScript();
    if (mounted) _captureNextPage();
  }

  Future<void> _onCompleteSession() async {
    await _finalizeCurrentScript();
    if (!mounted) return;

    if (_finalizedScripts.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    final markNow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Mark all scripts?'),
        content: Text(
          '${_finalizedScripts.length} script(s) were captured this session, entirely offline. Nothing has '
          'been sent anywhere yet.\n\nMark them all now against "${_scheme!.title}"? This is the point '
          "where they're sent for AI grading.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Yes, Mark All')),
        ],
      ),
    );
    if (!mounted) return;

    // Queue every script either way — "Not yet" still leaves them ready
    // to process later from the main hub, exactly like manually queuing.
    for (final script in _finalizedScripts) {
      await _repository.update(script.copyWith(status: MarkingScriptStatus.queued));
    }
    if (!mounted) return;

    if (markNow != true) {
      Navigator.of(context).pop();
      return;
    }

    setState(() => _finishing = true);
    var ranOutOfFreeGradings = false;
    await runBatchGrading(
      scripts: _finalizedScripts,
      scheme: _scheme!,
      repository: _repository,
      gradingService: _gradingService,
      onOutOfFreeGradings: () => ranOutOfFreeGradings = true,
    );
    if (!mounted) return;

    if (ranOutOfFreeGradings) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "You've used this month's free AI-graded scripts. The rest of this batch stays queued until "
            'next month (or an upgrade, once available).',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    }
    Navigator.of(context).pop();
  }

  void _removeCurrentPage(int index) => setState(() => _currentScriptPages.removeAt(index));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Batch Capture Scripts'),
        actions: [
          if (!_settingUp)
            TextButton(
              onPressed: _finishing ? null : _onCompleteSession,
              child: const Text('Complete Session', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _settingUp || _finishing
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  if (_finishing) ...[
                    const SizedBox(height: 12),
                    const Text('Grading all scripts…'),
                  ],
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_finalizedScripts.length} script(s) completed this session'
                          '${_detectedFirstName.isNotEmpty ? ' — now: $_detectedFirstName $_detectedSurname' : ''}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (_detectingName)
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                ),
                Expanded(
                  child: _currentScriptPages.isEmpty
                      ? const Center(child: Text('No pages captured for the current script yet.'))
                      : GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 0.75,
                          ),
                          itemCount: _currentScriptPages.length,
                          itemBuilder: (context, index) => Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(_currentScriptPages[index], fit: BoxFit.cover),
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
                                  onPressed: () => _removeCurrentPage(index),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        // Bottom-left camera icon — resumes capturing
                        // (the next page of the current script).
                        IconButton.filledTonal(
                          onPressed: _captureNextPage,
                          icon: const Icon(Icons.camera_alt_outlined),
                          tooltip: 'Capture next page',
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _currentScriptPages.isEmpty ? null : _onScriptCompleted,
                            icon: const Icon(Icons.check_circle_outline),
                            label: const Text('Script Completed'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
