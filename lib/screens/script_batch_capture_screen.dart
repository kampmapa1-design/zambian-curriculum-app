import 'dart:io';

import 'package:document_camera_frame/document_camera_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../models/marking_session.dart';
import '../models/syllabus_models.dart';
import '../services/batch_grading_runner.dart';
import '../services/duplicate_page_detector.dart';
import '../services/marking_grading_service.dart';
import '../services/marking_key_generation_service.dart';
import '../services/marking_scheme_key_picker.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import '../services/marking_session_repository.dart';
import '../services/template_repository.dart';
import 'marked_scripts_screen.dart';
import 'marking_key_upload_flow.dart';
import 'subject_grade_topic_picker_screen.dart';
import '../widgets/score_pop_badge.dart';

/// Which of the two real options a teacher picked when starting a new
/// cohort — see [_ScriptBatchCaptureScreenState._resolveMarkingKeyForNewCohort].
enum _KeySourceChoice { useSaved, uploadNew }

/// AI-Assisted Marking — "Upload Script" → "Upload through camera". One
/// script (its whole batch of pages — typically around 6) per screen visit,
/// but many scripts across one continuous *session* — see [MarkingSession].
/// A teacher captures every page of ONE candidate's script, taps "Script
/// Completed", and the screen stays put (pages still visible, still
/// addable) until they explicitly tap "Complete Session" to finish with
/// this script and return to the hub. Starting the NEXT script is a fresh,
/// deliberate action from the hub ("Upload Script" again) — not automatic
/// within one screen — but it no longer re-asks subject/grade/marking key,
/// or how many scripts remain: those are asked exactly once, at the very
/// start of a [MarkingSession], and persisted (see
/// [MarkingSessionRepository]) so they survive leaving the app entirely,
/// not just this screen closing.
///
/// The camera opens immediately (2026-08-31) — no picker screens gate it.
/// Subject/grade, the marking scheme, how many scripts this session plans
/// to capture, and the candidate's name/gender/ID/class are all asked in
/// [_completeSetup] right after the *first* page is captured, not before —
/// see [_captureNextPage]. This screen used to auto-detect the name from
/// the first captured page (a Gemini call, see CandidateNameDetectionService),
/// but that turned out to be a significant, avoidable share of this app's
/// AI cost at real scale (2026-08-30) for something a teacher can type in a
/// few seconds while the script is already in hand. CandidateNameDetectionService/
/// detectCandidateName are suspended, not deleted, in case a faster/cheaper
/// detection path is worth revisiting later. Gender is required right
/// alongside the name fields — every script this screen creates has a
/// real, teacher-given MarkingScript.genderConfirmed: true from the start,
/// not a placeholder MarkingReviewScreen has to stop and ask about later.
///
/// Nothing is sent anywhere until "Complete Session" → an explicit "Mark
/// this script now?" Yes — capture itself is entirely offline.
class ScriptBatchCaptureScreen extends StatefulWidget {
  const ScriptBatchCaptureScreen({
    super.key,
    this.repository,
    this.schemeRepository,
    this.gradingService,
    this.sessionRepository,
    this.templateRepository,
  });

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;
  final MarkingGradingService? gradingService;
  final MarkingSessionRepository? sessionRepository;
  final TemplateRepository? templateRepository;

  @override
  State<ScriptBatchCaptureScreen> createState() => _ScriptBatchCaptureScreenState();
}

class _ScriptBatchCaptureScreenState extends State<ScriptBatchCaptureScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final MarkingGradingService _gradingService = widget.gradingService ?? MarkingGradingService();
  late final MarkingSessionRepository _sessionRepository = widget.sessionRepository ?? MarkingSessionRepository();
  late final TemplateRepository _templateRepository = widget.templateRepository ?? TemplateRepository();

  bool _settingUp = true;

  /// True once subject/grade + scheme + student details have all been
  /// collected (see [_completeSetup]) — before that, [_captureNextPage]
  /// treats a newly captured page as "the first page, still need setup"
  /// rather than just adding it to an already-configured script.
  bool _setupComplete = false;
  SyllabusTemplate? _subjectGrade;
  MarkingScheme? _scheme;
  int _scriptNumber = 1;

  /// The active session (subject/scheme/target count), once resolved — see
  /// [_bootstrap]. Null only very briefly before that resolves, or if this
  /// screen was closed before any session ever started.
  MarkingSession? _session;

  final List<File> _pages = [];

  /// One entry per [_pages], same index, kept in sync by every place that
  /// adds/removes a page — see [_flagIfDuplicatePage]. Null for a page
  /// whose hash hasn't been computed yet, or failed to (never blocks
  /// capture either way — a duplicate check is a nice-to-have, not a
  /// precondition for capturing).
  final List<BigInt?> _pageHashes = [];
  final DuplicatePageDetector _duplicateDetector = DuplicatePageDetector();

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// Resolves whatever session is already active — a real disk read, not a
  /// network call, so this adds no perceptible delay before the camera
  /// opens (see this class's own doc comment on why the camera isn't
  /// gated). A session whose stated target was already reached (the
  /// screen closed at exactly the wrong moment last time) is treated the
  /// same as no session — nothing to resume, ask fresh.
  Future<void> _bootstrap() async {
    final active = await _sessionRepository.getActive();
    if (mounted) {
      if (active != null) {
        final latestUsed = (await _repository.nextScriptNumber()) - 1;
        if (!mounted) return;
        if (active.isCompleteGiven(latestUsed)) {
          await _sessionRepository.end();
        } else {
          _session = active;
        }
      }
    }
    if (mounted) _captureNextPage();
  }

  /// Runs right after the first page is captured (see [_captureNextPage])
  /// rather than before — subject/grade, the marking scheme, how many
  /// scripts this session plans to capture, and the candidate's details no
  /// longer gate opening the camera at all. Returns false if the teacher
  /// backs out at any point, in which case the caller discards this
  /// attempt and returns to the hub.
  Future<bool> _completeSetup() async {
    setState(() => _settingUp = true);
    SyllabusTemplate template;
    MarkingScheme scheme;

    if (_session case final session?) {
      // Resuming an already-active session (the very common case: this is
      // the 2nd+ script of the same sitting, or the teacher left the app
      // entirely and came back) — never re-ask subject/grade/scheme/count,
      // see MarkingSession's own doc comment on why this is persisted.
      final reloadedTemplate = await _templateRepository.loadSyllabus(
        curriculumCode: session.curriculumCode,
        subjectCode: session.subjectCode,
        gradeLevel: session.gradeLevel,
      );
      final schemeCatalog = await _schemeRepository.loadCatalog();
      final reloadedScheme = schemeCatalog.schemes.where((s) => s.id == session.schemeId).firstOrNull;
      if (!mounted) return false;

      if (reloadedTemplate == null || reloadedScheme == null) {
        // What this session pointed to no longer exists (e.g. the marking
        // key was deleted mid-session) — can't silently resume against
        // nothing. End the stale session and fall through to asking fresh,
        // same as if none had existed, rather than failing outright.
        await _sessionRepository.end();
        _session = null;
      } else {
        template = reloadedTemplate;
        scheme = reloadedScheme;
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
    }

    // No active session — the real first-time setup: subject & grade, the
    // marking key, and (new, per explicit request) how many scripts this
    // session plans to capture, so none of it needs re-asking for every
    // script in the same sitting.
    if (!mounted) return false;
    final pickedTemplate = await Navigator.of(context).push<SyllabusTemplate>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Subject & Grade'),
      ),
    );
    if (!mounted) return false;
    if (pickedTemplate == null) return false;

    final pickedScheme = await _resolveMarkingKeyForNewCohort(pickedTemplate);
    if (!mounted) return false;
    if (pickedScheme == null) return false;
    template = pickedTemplate;
    scheme = pickedScheme;

    final cohortDetails = await _askCohortDetails();
    if (!mounted) return false;
    if (cohortDetails == null) return false;

    final targetCount = await _askTargetScriptCount();
    if (!mounted) return false;
    if (targetCount == null) return false;

    final details = await _askScriptDetails(initialClassLevel: cohortDetails.className);
    if (!mounted) return false;
    if (details == null) return false;

    final startNumber = await _repository.nextScriptNumber();
    if (!mounted) return false;

    final newSession = MarkingSession(
      curriculumCode: template.curriculum.code,
      subjectCode: template.subject.code,
      gradeLevel: template.grade.level,
      subjectName: template.subject.name,
      gradeName: template.grade.name,
      schemeId: scheme.id,
      schemeTitle: scheme.title,
      cohortName: cohortDetails.cohortName,
      examLevel: cohortDetails.examLevel,
      className: cohortDetails.className,
      targetScriptCount: targetCount,
      startScriptNumber: startNumber,
      startedAt: DateTime.now(),
    );
    await _sessionRepository.start(newSession);
    if (!mounted) return false;

    setState(() {
      _session = newSession;
      _subjectGrade = template;
      _scheme = scheme;
      _scriptNumber = startNumber;
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

  /// Asked once, right after a marking key is chosen/uploaded for a new
  /// cohort (2026-09-05, per explicit request): a real name for this
  /// cohort, the exam's level, and the class being marked — e.g. "Grade
  /// 12 Mock Exam", "Grade 12", "12A". Deliberately free text with NO
  /// validation against the marking key's own subject/title/level — the
  /// explicit request was that these "should not block the marking
  /// process even if the name or details given to the cohort do not
  /// exactly match with the title of the marking key selected", since a
  /// real class/exam sitting is very often named differently from
  /// however the key itself was titled when it was uploaded (the same
  /// key is routinely reused across several different classes). Stored
  /// on the new MarkingSession and stamped onto every script saved during
  /// it (see MarkingScript.cohortName) purely so cohorts stay tellable
  /// apart later, never to gate anything. Returns null if the teacher
  /// backs out.
  Future<_CohortDetails?> _askCohortDetails() {
    final cohortNameController = TextEditingController();
    final examLevelController = TextEditingController();
    final classNameController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    return showDialog<_CohortDetails>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Name this cohort'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'A few words to tell this class/sitting apart later — especially useful if you mark the '
                    'same paper for more than one class. These don\'t need to match the marking key\'s own '
                    'title.',
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: cohortNameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Cohort name (e.g. "Grade 12 Mock Exam")',
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.sentences,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: examLevelController,
                    decoration: const InputDecoration(
                      labelText: 'Level of the exam (e.g. "Grade 12")',
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.words,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: classNameController,
                    decoration: const InputDecoration(
                      labelText: 'Name of the class (e.g. "12A")',
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.words,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
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
              if (!(formKey.currentState?.validate() ?? false)) return;
              Navigator.of(dialogContext).pop(_CohortDetails(
                cohortName: cohortNameController.text.trim(),
                examLevel: examLevelController.text.trim(),
                className: classNameController.text.trim(),
              ));
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  /// Asked once, at the very start of a new session — per explicit request
  /// ("add a requirement to indicate the number of scripts on the first
  /// page so that it will not be requiring the re-stating of the subject
  /// being marked"). A rough estimate is fine; it only decides when this
  /// session auto-ends (see MarkingSession.isCompleteGiven) — nothing is
  /// blocked or rejected for running over or under it. Returns null if the
  /// teacher backs out.
  Future<int?> _askTargetScriptCount() {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('How many scripts?'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('How many scripts do you plan to capture in this session? Asked once — every script '
                  'after this one reuses the same subject and marking key automatically.'),
              const SizedBox(height: 16),
              TextFormField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Number of scripts', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (v) {
                  final n = int.tryParse(v?.trim() ?? '');
                  if (n == null || n <= 0) return 'Enter a number greater than 0';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (!(formKey.currentState?.validate() ?? false)) return;
              Navigator.of(dialogContext).pop(int.parse(controller.text.trim()));
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
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
  Future<_ScriptDetails?> _askScriptDetails({String initialClassLevel = ''}) {
    final firstNameController = TextEditingController();
    final surnameController = TextEditingController();
    final idController = TextEditingController();
    // Pre-filled from the cohort's own "name of the class" (asked once, at
    // the very start of the cohort — see _askCohortDetails) so the very
    // first script doesn't make a teacher retype what they just entered;
    // still freely editable per script, same as before this existed.
    final classLevelController = TextEditingController(text: initialClassLevel);
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

  String _formatSchemeDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// "Use a saved marking key, or upload a new one?" — real, reported gap
  /// (2026-09-05): the previous version only ever offered marking keys
  /// whose own typed subject name matched the bundled syllabus subject
  /// EXACTLY (case/whitespace aside). A teacher who typed "History Paper
  /// 1" and "History Paper 2" when uploading two real keys — a completely
  /// reasonable way to name them — never saw either one here once they
  /// picked the bundled "History" subject (the syllabus has no "Paper 1"/
  /// "Paper 2" split), and the app wrongly reported "no marking key
  /// uploaded" despite both being safely saved. Now offers both real
  /// options explicitly at the start of every new cohort, and
  /// [_pickAnyMarkingScheme] always shows every saved key regardless of
  /// subject-name wording, never hiding one behind a filter that can
  /// silently fail. Loops back to this same choice if either path is
  /// backed out of, rather than dead-ending the whole "start a cohort"
  /// attempt on a single misstep.
  Future<MarkingScheme?> _resolveMarkingKeyForNewCohort(SyllabusTemplate pickedTemplate) async {
    while (true) {
      if (!mounted) return null;
      final choice = await showDialog<_KeySourceChoice>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Use a saved marking key, or upload a new one?'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(_KeySourceChoice.useSaved),
              child: const Text('Use a saved marking key'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(_KeySourceChoice.uploadNew),
              child: const Text('Upload a new one'),
            ),
          ],
        ),
      );
      if (!mounted || choice == null) return null;

      if (choice == _KeySourceChoice.useSaved) {
        final picked = await _pickAnyMarkingScheme(pickedTemplate);
        if (!mounted) return null;
        if (picked != null) return picked;
        continue; // backed out of the list, or nothing saved yet — ask again
      }

      final uploaded = await _uploadNewMarkingKeyInline();
      if (!mounted) return null;
      if (uploaded != null) return uploaded;
      continue; // backed out of the upload flow — ask again
    }
  }

  /// Every saved marking key, regardless of subject — see
  /// [_resolveMarkingKeyForNewCohort]'s own doc comment on why this no
  /// longer filters by an exact subject-name match. Keys whose own
  /// subject name matches [pickedTemplate]'s real syllabus subject are
  /// listed first under their own heading (still the common, convenient
  /// case), everything else follows under "Other saved keys" — labeled
  /// with its own subject name so a different subject's key is never
  /// mistaken for this one — rather than being hidden entirely.
  Future<MarkingScheme?> _pickAnyMarkingScheme(SyllabusTemplate pickedTemplate) async {
    final schemes = await _schemeRepository.loadCatalog();
    if (!mounted) return null;
    if (schemes.schemes.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('No marking keys saved yet'),
          content: const Text('Upload one first, then come back to start this cohort.'),
          actions: [FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK'))],
        ),
      );
      return null;
    }

    final (:matching, :other) = splitMarkingSchemesBySubjectMatch(schemes.schemes, pickedTemplate.subject.name);

    if (!mounted) return null;
    return showDialog<MarkingScheme>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Which marking key should this session use?'),
        children: [
          if (matching.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(pickedTemplate.subject.name, style: Theme.of(dialogContext).textTheme.labelMedium),
            ),
            for (final s in matching)
              SimpleDialogOption(
                onPressed: () => Navigator.of(dialogContext).pop(s),
                child: Text('${s.title} — ${_formatSchemeDate(s.createdAt)} (${s.questions.length} question(s))'),
              ),
          ],
          if (other.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('Other saved keys', style: Theme.of(dialogContext).textTheme.labelMedium),
            ),
            for (final s in other)
              SimpleDialogOption(
                onPressed: () => Navigator.of(dialogContext).pop(s),
                child: Text('${s.subjectName} — ${s.title} — ${_formatSchemeDate(s.createdAt)}'),
              ),
          ],
        ],
      ),
    );
  }

  /// "Upload a new one" — the device/camera choice a teacher would
  /// otherwise only see from the AutoGrade hub's own "Upload Marking Key"
  /// button, now reachable right at the point a new cohort actually needs
  /// one, so uploading and then immediately using it for this session
  /// doesn't require backing all the way out to the hub and back in.
  /// Runs the exact same shared flow (marking_key_upload_flow.dart) as
  /// every other entry point into it.
  Future<MarkingScheme?> _uploadNewMarkingKeyInline() async {
    final method = await showModalBottomSheet<MarkingKeyUploadMethod>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Upload through camera'),
              onTap: () => Navigator.of(sheetContext).pop(MarkingKeyUploadMethod.camera),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Upload from device'),
              onTap: () => Navigator.of(sheetContext).pop(MarkingKeyUploadMethod.uploadFromDevice),
            ),
          ],
        ),
      ),
    );
    if (!mounted || method == null) return null;
    return runMarkingKeyUploadFlow(
      context: context,
      sourceType: MarkingKeySourceType.markingKey,
      method: method,
      schemeRepository: _schemeRepository,
    );
  }

  Future<void> _captureNextPage() async {
    // Real, reported gap (2026-09-10): on some devices the package's own
    // post-capture "Use this photo"/"Retake" buttons sit low enough to be
    // obscured — most likely by the system's own bottom gesture-navigation
    // inset, which this call wasn't accounting for. Read before pushing
    // the route (this screen's own context, not the camera route's).
    final bottomInset = MediaQuery.of(context).padding.bottom;
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
          // Explicit bottom clearance for "Use this photo"/"Retake" (see
          // this method's own comment above) — the package's own default
          // position doesn't reserve room for a device's bottom gesture
          // inset on its own.
          buttonStyle: DocumentCameraButtonStyle(
            actionButtonAlignment: Alignment.bottomCenter,
            actionButtonPadding: EdgeInsets.only(bottom: bottomInset + 28),
          ),
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

    final newPage = File(result.frontImagePath!);
    setState(() {
      _pages.add(newPage);
      _pageHashes.add(null);
    });
    await _flagIfDuplicatePage(newPage, _pages.length - 1);
    if (!mounted) return;

    if (!_setupComplete) {
      // The camera opened before any of this was known (see this class's
      // doc comment) — now that there's a first page in hand, collect
      // whatever setup this session still needs (nothing at all, if
      // resuming an already-active one).
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
      cohortName: _session?.cohortName ?? '',
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

    // This script just pushed the session to (or past) its stated target —
    // end it now, so the *next* "Upload Script" from the hub asks fresh
    // rather than silently continuing an already-"finished" session.
    if (_session case final session? when session.isCompleteGiven(_scriptNumber)) {
      await _sessionRepository.end();
    }
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

  void _removePage(int index) => setState(() {
        _pages.removeAt(index);
        if (index < _pageHashes.length) _pageHashes.removeAt(index);
      });

  /// Duplicate-page flagging (2026-09-10, per explicit request): compares
  /// the just-captured page at [newIndex] against the one right before
  /// it — the real, easy mistake this catches is the camera (with
  /// [DocumentCameraFrame.enableAutoCapture] on) firing again on the same
  /// physical page before the teacher has turned to the next one, not two
  /// genuinely different pages that happen to look similar. Only ever
  /// flags for the TEACHER to decide — never removes anything on its own,
  /// and a "Keep Both" choice (or this check failing/being inconclusive
  /// for any reason) leaves capture free to continue exactly as normal;
  /// this is a convenience, never a gate on the batch actually processing.
  Future<void> _flagIfDuplicatePage(File newPage, int newIndex) async {
    try {
      final hash = await _duplicateDetector.computeHash(newPage);
      if (!mounted || newIndex >= _pageHashes.length) return;
      setState(() => _pageHashes[newIndex] = hash);

      if (newIndex == 0) return; // Nothing before it to compare against.
      var previousHash = _pageHashes[newIndex - 1];
      previousHash ??= await _duplicateDetector.computeHash(_pages[newIndex - 1]);
      if (!mounted || newIndex >= _pageHashes.length) return;
      setState(() => _pageHashes[newIndex - 1] = previousHash);

      if (!_duplicateDetector.looksLikeDuplicate(hash, previousHash)) return;

      final remove = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Same page again?'),
          content: Text(
            'Page ${newIndex + 1} looks like it might be the same page as Page $newIndex — the camera can '
            'sometimes fire again before you\'ve turned to the next one. Remove the new copy, or keep both '
            'if they\'re genuinely different pages?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep Both')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Remove This One')),
          ],
        ),
      );
      if (remove == true && mounted && newIndex < _pages.length) {
        _removePage(newIndex);
      }
    } catch (_) {
      // Never lets a duplicate-check failure block real capture — see
      // this method's own doc comment.
    }
  }

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

  /// e.g. "Script 4 of 10 this session" — shown once a session is known,
  /// so a teacher can see at a glance that their progress genuinely
  /// carried over (across scripts, or across leaving and returning to the
  /// app), not just trust it silently.
  String? get _sessionProgressLabel {
    final session = _session;
    if (session == null) return null;
    final soFar = session.capturedCountGiven(_scriptNumber).clamp(1, session.targetScriptCount);
    return 'Script $soFar of ${session.targetScriptCount} this session — ${session.subjectName}, ${session.gradeName}';
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
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
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
                if (_sessionProgressLabel case final label?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      label,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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

/// Result of [_ScriptBatchCaptureScreenState._askCohortDetails] — plain
/// data, no behavior.
class _CohortDetails {
  const _CohortDetails({
    required this.cohortName,
    required this.examLevel,
    required this.className,
  });

  final String cohortName;
  final String examLevel;
  final String className;
}
