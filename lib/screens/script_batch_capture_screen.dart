import 'dart:io';

import 'package:document_camera_frame/document_camera_frame.dart';
import 'package:flutter/material.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../models/syllabus_models.dart';
import '../services/batch_grading_runner.dart';
import '../services/marking_grading_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import 'marked_scripts_screen.dart';
import 'subject_grade_topic_picker_screen.dart';
import '../widgets/score_pop_badge.dart';

/// AI-Assisted Marking — "Upload Script" → "Upload through camera". One
/// script (its whole batch of pages — typically around 6) per screen,
/// not several scripts chained together: a teacher captures every page
/// of ONE candidate's script, taps "Script Completed", and the screen
/// stays put (pages still visible, still addable) until they explicitly
/// tap "Complete Session" to finish with this script and return to the
/// hub. Starting the NEXT script is a fresh, deliberate action from the
/// hub ("Upload Script" again) — not automatic — so a teacher can stop
/// and review/correct a script (via the hub, or MarkingReviewScreen once
/// it's graded) before ever starting the next one.
///
/// The camera opens immediately (2026-08-31) — no picker screens gate
/// it. Subject/grade, the marking scheme, and the candidate's
/// name/gender/ID/class are all asked in [_completeSetup] right after
/// the *first* page is captured, not before — see [_captureNextPage].
/// This screen used to auto-detect the name from the first captured page
/// (a Gemini call, see CandidateNameDetectionService), but that turned
/// out to be a significant, avoidable share of this app's AI cost at
/// real scale (2026-08-30) for something a teacher can type in a few
/// seconds while the script is already in hand. CandidateNameDetectionService/
/// detectCandidateName are suspended, not deleted, in case a faster/
/// cheaper detection path is worth revisiting later. Gender is required
/// right alongside the name fields — every script this screen creates
/// has a real, teacher-given MarkingScript.genderConfirmed: true from
/// the start, not a placeholder MarkingReviewScreen has to stop and ask
/// about later.
///
/// Nothing is sent anywhere until "Complete Session" → an explicit "Mark
/// this script now?" Yes — capture itself is entirely offline.
class ScriptBatchCaptureScreen extends StatefulWidget {
  const ScriptBatchCaptureScreen({
    super.key,
    this.repository,
    this.schemeRepository,
    this.gradingService,
    this.initialTemplate,
    this.initialScheme,
    this.onSetupComplete,
  });

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;
  final MarkingGradingService? gradingService;

  /// When both are given (2026-08-31), [_setUp] skips straight past the
  /// Subject & Grade and "which marking key" pickers and starts this
  /// script's details form directly — set by MarkingQueueScreen from
  /// whatever the *previous* script in this session used, since asking
  /// again for every single script in the same marking session is pure
  /// repetition: those details were already given once, at the start.
  /// Null (the ordinary case) runs the pickers as before.
  final SyllabusTemplate? initialTemplate;
  final MarkingScheme? initialScheme;

  /// Fired once [_setUp] has a confirmed template+scheme — whether just
  /// picked fresh or reused from [initialTemplate]/[initialScheme] — so
  /// MarkingQueueScreen can remember them for the *next* script too.
  final void Function(SyllabusTemplate template, MarkingScheme scheme)? onSetupComplete;

  @override
  State<ScriptBatchCaptureScreen> createState() => _ScriptBatchCaptureScreenState();
}

class _ScriptBatchCaptureScreenState extends State<ScriptBatchCaptureScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final MarkingGradingService _gradingService = widget.gradingService ?? MarkingGradingService();

  bool _settingUp = true;

  /// True once subject/grade + scheme + student details have all been
  /// collected (see [_completeSetup]) — before that, [_captureNextPage]
  /// treats a newly captured page as "the first page, still need setup"
  /// rather than just adding it to an already-configured script.
  bool _setupComplete = false;
  SyllabusTemplate? _subjectGrade;
  MarkingScheme? _scheme;
  int _scriptNumber = 1;

  final List<File> _pages = [];
  String _firstName = '';
  String _surname = '';
  CandidateGender _gender = CandidateGender.male;
  String _studentId = '';
  String _classLevel = '';

  /// Set once "Script Completed" is tapped — the script is saved from
  /// that point on (and re-saved if more pages are added afterward), but
  /// the screen stays open so the teacher can still add a missed page
  /// before "Complete Session".
  bool _scriptSaved = false;
  MarkingScript? _savedScript;
  bool _finishing = false;

  // The "score just came in" pop-and-fade — see [ScorePopBadge]. This
  // screen is the real, primary path a script gets AI-graded through (one
  // script per "Complete Session"), unlike MarkingQueueScreen's batch
  // "Process" button — the pop-up wasn't wired here at all before
  // 2026-08-31, which is why it never appeared on a real device despite
  // being wired into the queue screen.
  MarkingScript? _justGradedScript;
  double? _justGradedPercent;
  int _scorePopKey = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _captureNextPage());
  }

  /// Runs right after the first page is captured (see [_captureNextPage])
  /// rather than before — subject/grade, the marking scheme, and the
  /// candidate's details no longer gate opening the camera at all.
  /// Returns false if the teacher backs out at any point, in which case
  /// the caller discards this attempt and returns to the hub.
  Future<bool> _completeSetup() async {
    setState(() => _settingUp = true);
    SyllabusTemplate template;
    MarkingScheme scheme;

    if (widget.initialTemplate != null && widget.initialScheme != null) {
      // Reused from the previous script in this session — see
      // [ScriptBatchCaptureScreen.initialTemplate]'s doc. Skips both
      // pickers entirely.
      template = widget.initialTemplate!;
      scheme = widget.initialScheme!;
    } else {
      final pickedTemplate = await Navigator.of(context).push<SyllabusTemplate>(
        MaterialPageRoute(
          builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Subject & Grade', pickTopic: false),
        ),
      );
      if (!mounted) return false;
      if (pickedTemplate == null) return false;

      final schemes = await _schemeRepository.loadCatalog();
      if (!mounted) return false;
      if (schemes.schemes.isEmpty) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('No marking scheme yet'),
            content: const Text(
              'This script needs a marking key to grade against. Upload or build one first, then capture this script again.',
            ),
            actions: [FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK'))],
          ),
        );
        return false;
      }

      final pickedScheme = await showDialog<MarkingScheme>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Which marking key is this script for?'),
          children: [
            for (final s in schemes.schemes)
              SimpleDialogOption(
                onPressed: () => Navigator.of(dialogContext).pop(s),
                child: Text('${s.title} (${s.questions.length} question(s))'),
              ),
          ],
        ),
      );
      if (!mounted) return false;
      if (pickedScheme == null) return false;
      template = pickedTemplate;
      scheme = pickedScheme;
    }

    widget.onSetupComplete?.call(template, scheme);

    final details = await _askScriptDetails();
    if (!mounted) return false;
    if (details == null) return false;

    final nextNumber = await _repository.nextScriptNumber();
    if (!mounted) return false;
    setState(() {
      _subjectGrade = template;
      _scheme = scheme;
      _scriptNumber = nextNumber;
      _firstName = details.firstName;
      _surname = details.surname;
      _gender = details.gender;
      _studentId = details.studentId;
      _classLevel = details.classLevel;
      _settingUp = false;
      _setupComplete = true;
    });
    return true;
  }

  /// Asked once, before any page is captured — replaces the AI name
  /// detection this screen used to run after the first photo (see this
  /// class's doc comment). Gender is required here too (2026-08-31) —
  /// right after the name fields — rather than deferred to review: a
  /// two-tap selector doesn't meaningfully slow down "just capture, keep
  /// going" the way per-script AI detection did, and every script this
  /// screen saves now has a real, teacher-confirmed gender from the start
  /// instead of a placeholder needing correction later. Returns null if
  /// the teacher backs out.
  Future<_ScriptDetails?> _askScriptDetails() {
    final firstNameController = TextEditingController();
    final surnameController = TextEditingController();
    final idController = TextEditingController();
    final classLevelController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    CandidateGender? gender;
    String? genderError;

    return showDialog<_ScriptDetails>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Whose script is this?'),
          // Wrapped in a scroll view (2026-08-31) — an AlertDialog's
          // content doesn't scroll on its own, so on a real device with
          // the on-screen keyboard open, this many fields could overflow
          // and visually collide with the Cancel/Continue actions below
          // instead of leaving room for them. Scrolling internally means
          // the actions always stay clear of the fields, regardless of
          // screen size or keyboard state.
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                TextFormField(
                  controller: firstNameController,
                  decoration: const InputDecoration(labelText: 'First name', border: OutlineInputBorder()),
                  textCapitalization: TextCapitalization.words,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: surnameController,
                  decoration: const InputDecoration(labelText: 'Surname', border: OutlineInputBorder()),
                  textCapitalization: TextCapitalization.words,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                Text('Gender', style: Theme.of(dialogContext).textTheme.labelLarge),
                const SizedBox(height: 4),
                SegmentedButton<CandidateGender>(
                  segments: const [
                    ButtonSegment(value: CandidateGender.male, label: Text('Male')),
                    ButtonSegment(value: CandidateGender.female, label: Text('Female')),
                  ],
                  selected: {if (gender != null) gender!},
                  emptySelectionAllowed: true,
                  onSelectionChanged: (selection) => setDialogState(() {
                    gender = selection.firstOrNull;
                    genderError = null;
                  }),
                ),
                if (genderError != null) ...[
                  const SizedBox(height: 4),
                  Text(genderError!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error, fontSize: 12)),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: idController,
                  decoration: const InputDecoration(labelText: 'Student ID (optional)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: classLevelController,
                  decoration: const InputDecoration(
                    labelText: 'Class / Level (e.g. "10A", "Form 2 Blue")',
                    border: OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.words,
                ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final formOk = formKey.currentState?.validate() ?? false;
                if (gender == null) {
                  setDialogState(() => genderError = 'Required');
                }
                if (!formOk || gender == null) return;
                Navigator.of(dialogContext).pop(
                  _ScriptDetails(
                    firstName: firstNameController.text.trim(),
                    surname: surnameController.text.trim(),
                    gender: gender!,
                    studentId: idController.text.trim(),
                    classLevel: classLevelController.text.trim(),
                  ),
                );
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
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
          bottomHintText: _pages.isEmpty
              ? 'Page 1 of this script (scripts typically run around 6 pages)'
              : 'Page ${_pages.length + 1} of this script',
          // No onDocumentSaved here — see the identical comment in
          // DocumentPagesCaptureScreen._captureNextPage for why: the
          // plugin already pops itself with the result, and also popping
          // here double-popped the navigator, silently closing this
          // screen right after each capture.
        ),
      ),
    );

    if (!mounted) return;
    if (result == null || !result.hasFrontSide || result.frontImagePath == null) {
      if (_pages.isEmpty) Navigator.of(context).pop();
      return;
    }

    setState(() => _pages.add(File(result.frontImagePath!)));

    if (!_setupComplete) {
      // The camera opened before any of this was known (see this class's
      // doc comment) — now that there's a first page in hand, collect
      // subject/grade, the marking scheme, and the candidate's details.
      final ok = await _completeSetup();
      if (!mounted) return;
      if (!ok) {
        // Backed out of setup entirely — nothing was ever saved (setup
        // completing is a precondition for _saveOrUpdateScript), so
        // there's nothing to clean up beyond just leaving.
        Navigator.of(context).pop();
        return;
      }
      return;
    }

    // If the script was already saved (a page added after "Script
    // Completed" — the resume-capture path) keep it in sync immediately.
    if (_scriptSaved) await _saveOrUpdateScript();
  }

  Future<void> _saveOrUpdateScript() async {
    if (_pages.isEmpty) return;
    if (_savedScript != null) {
      // A page was added after the script was already saved once — the
      // simplest correct way to keep the saved copy in sync is to remove
      // and re-save it with the current full page set.
      await _repository.remove(_savedScript!);
    }
    final script = await _repository.saveScript(
      firstName: _firstName,
      surname: _surname,
      gender: _gender,
      studentIdNumber: _studentId.isEmpty ? null : _studentId,
      scriptNumber: _scriptNumber,
      subjectName: _subjectGrade!.subject.name,
      gradeName: _subjectGrade!.grade.name,
      classLevel: _classLevel,
      capturedPageFiles: _pages,
    );
    // Gender is now collected up front (see _askScriptDetails) and is
    // real, teacher-given data — genderConfirmed: true, not the
    // placeholder-needing-review flag this used to always set.
    final linked = script.copyWith(schemeId: _scheme!.id, genderConfirmed: true);
    await _repository.update(linked);
    _savedScript = linked;
  }

  Future<void> _onScriptCompleted() async {
    if (_pages.isEmpty) return;
    await _saveOrUpdateScript();
    if (mounted) setState(() => _scriptSaved = true);
  }

  Future<void> _onCompleteSession() async {
    if (!_scriptSaved) await _onScriptCompleted();
    if (!mounted || _savedScript == null) return;

    final markNow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Mark this script?'),
        content: Text(
          'This script was captured entirely offline — nothing has been sent anywhere yet.\n\nMark it now '
          'against "${_scheme!.title}"? This is the point where it\'s sent for AI grading.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Yes, Mark It')),
        ],
      ),
    );
    if (!mounted) return;

    await _repository.update(_savedScript!.copyWith(status: MarkingScriptStatus.queued));
    if (!mounted) return;

    if (markNow != true) {
      Navigator.of(context).pop();
      return;
    }

    setState(() => _finishing = true);
    var ranOutOfFreeGradings = false;
    final scheme = _scheme!;
    await runBatchGrading(
      scripts: [_savedScript!],
      scheme: scheme,
      repository: _repository,
      gradingService: _gradingService,
      onOutOfFreeGradings: () => ranOutOfFreeGradings = true,
      onScriptGraded: (graded) {
        if (!mounted || graded.status != MarkingScriptStatus.graded) return;
        final total = scheme.totalMarks;
        setState(() {
          _justGradedScript = graded;
          _justGradedPercent = total <= 0 ? 0 : ((graded.totalAwarded ?? 0) / total) * 100;
          _scorePopKey++;
        });
      },
    );
    if (!mounted) return;

    if (ranOutOfFreeGradings) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "You've used this month's free AI-graded scripts this month — this script stays queued until "
            'next month (or an upgrade, once available).',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    }

    // Give the score pop-up its full ~3.5s before leaving this screen —
    // popping immediately (the old behavior) meant the badge never had a
    // chance to actually be seen, even once it was wired up.
    if (_justGradedScript != null) {
      await Future.delayed(const Duration(milliseconds: 3500));
      if (!mounted) return;
    }
    Navigator.of(context).pop();
  }

  void _removePage(int index) => setState(() => _pages.removeAt(index));

  Widget _buildScorePopOverlay() {
    if (_justGradedScript case final graded?) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 24),
          child: ScorePopBadge(
            key: ValueKey(_scorePopKey),
            studentName: graded.fullName,
            percent: _justGradedPercent ?? 0,
            onDone: () {
              if (mounted) setState(() => _justGradedScript = null);
            },
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Capture Script'),
        actions: [
          // Available throughout — not just once this script is done —
          // so a teacher can jump to a script that needs a closer look
          // without losing their place mid-capture (2026-08-31).
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MarkedScriptsScreen(repository: _repository, schemeRepository: _schemeRepository),
              ),
            ),
            icon: const Icon(Icons.fact_check_outlined),
            tooltip: 'View Marked Scripts',
          ),
          if (!_settingUp && !_finishing)
            TextButton(
              onPressed: _pages.isEmpty ? null : _onCompleteSession,
              child: const Text('Complete Session', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Stack(
        children: [
          _settingUp || _finishing
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      if (_finishing) ...[
                        const SizedBox(height: 12),
                        const Text('Grading this script…'),
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
                          _scriptSaved
                              ? 'Script saved — $_firstName $_surname. '
                                  'Add another page if needed, or tap "Complete Session" above when done.'
                              : 'Capturing Script $_scriptNumber — $_firstName $_surname',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _pages.isEmpty
                      ? const Center(child: Text('No pages captured yet.'))
                      : GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 0.75,
                          ),
                          itemCount: _pages.length,
                          itemBuilder: (context, index) => Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(_pages[index], fit: BoxFit.cover),
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
                                  onPressed: () => _removePage(index),
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
                        // Bottom-left camera icon — keeps adding pages to
                        // this same script, available even after "Script
                        // Completed" in case a page was missed.
                        IconButton.filledTonal(
                          onPressed: _captureNextPage,
                          icon: const Icon(Icons.camera_alt_outlined),
                          tooltip: 'Capture next page',
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _pages.isEmpty || _scriptSaved ? null : _onScriptCompleted,
                            icon: const Icon(Icons.check_circle_outline),
                            label: Text(_scriptSaved ? 'Script Saved' : 'Script Completed'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          _buildScorePopOverlay(),
        ],
      ),
    );
  }
}

/// Result of [_ScriptBatchCaptureScreenState._askScriptDetails] — plain
/// data, no behavior.
class _ScriptDetails {
  const _ScriptDetails({
    required this.firstName,
    required this.surname,
    required this.gender,
    required this.studentId,
    required this.classLevel,
  });

  final String firstName;
  final String surname;
  final CandidateGender gender;
  final String studentId;
  final String classLevel;
}
