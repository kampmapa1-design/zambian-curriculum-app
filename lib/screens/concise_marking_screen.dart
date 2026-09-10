import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/marking_rubric.dart';
import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/concise_cohort_score_list_document_service.dart';
import '../services/concise_marking_service.dart';
import '../services/concise_score_calculator.dart';
import '../services/marking_entitlement_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import '../services/script_annotation_service.dart';
import 'burst_capture_screen.dart';
import 'document_pages_capture_screen.dart';

/// "Concise Marking" (Scan Marker) — a whole marking SESSION for one exam,
/// run as a PURE AI marking engine (2026-09-10, per explicit request:
/// "concise marker is supposed to be purely AI as a priority").
///
/// No marking key is required or asked for. The AI reads the questions,
/// their mark allocations and the marking guidance off the script (and an
/// optional photo of the question paper), marks every answer from its own
/// subject expertise, reads the section rules off the first script's cover
/// page and reuses them, then the app scores every paper out of 100
/// deterministically ([ConciseScoreCalculator]). Where the app finds a
/// saved marking key matching the subject it is passed to the AI as
/// REFERENCE only — blended, never the authority, never blocking.
///
/// The real ticks/crosses on the actual photographed pages
/// ([ScriptAnnotationService]), the fallback generated page, the on-script
/// score stamp + report, and the Word/PDF cohort score list are all as
/// before.
///
/// Reachable three ways: its own dropdown on the Scan Marker hub ("Upload
/// from device / camera / a queued list" — see [initialSource]); as a
/// "Concise Marker" choice in the marking-key picker when queuing
/// freshly-captured scripts (see [pendingScripts]); or opened bare.
enum ConciseMarkingSource { device, camera, queue }

class ConciseMarkingScreen extends StatefulWidget {
  const ConciseMarkingScreen({
    super.key,
    this.repository,
    this.schemeRepository,
    this.gradingService,
    this.annotationService,
    this.initialSource,
    this.pendingScripts = const [],
  });

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;
  final ConciseMarkingService? gradingService;
  final ScriptAnnotationService? annotationService;

  /// When set, the screen skips its setup card, asks only for the subject
  /// name, and launches this source picker straight away.
  final ConciseMarkingSource? initialSource;

  /// Freshly-captured scripts routed here from the "Concise Marker" option
  /// in the marking-key picker — added to the session on open and marked
  /// by the AI directly.
  final List<MarkingScript> pendingScripts;

  @override
  State<ConciseMarkingScreen> createState() => _ConciseMarkingScreenState();
}

enum _Phase { setup, session }

enum _ItemStatus { pending, marking, marked, failed }

class _SessionItem {
  _SessionItem({
    required this.id,
    required this.script,
    required this.candidateName,
    this.referenceScheme,
    this.questionPaperFiles = const [],
  });

  final int id;
  MarkingScript script;
  String candidateName;

  /// A saved marking key the app auto-detected for this subject (or the
  /// key a queued script was already linked to) — passed to the AI as
  /// reference only, never as the authority.
  MarkingScheme? referenceScheme;

  /// Optional extra images of the question paper / marking guide.
  List<File> questionPaperFiles;

  _ItemStatus status = _ItemStatus.pending;
  ConciseScore? score;
  List<File> annotatedPages = [];
  File? reportPdf;
  File? fallbackPdf;
  List<String> observations = [];
  String? error;
}

class _ConciseMarkingScreenState extends State<ConciseMarkingScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final ConciseMarkingService _gradingService = widget.gradingService ?? ConciseMarkingService();
  late final ScriptAnnotationService _annotationService = widget.annotationService ?? ScriptAnnotationService();

  bool _loading = true;
  String? _loadError;
  List<MarkingScript> _eligibleScripts = [];
  MarkingSchemeCatalog _schemes = MarkingSchemeCatalog.empty();

  _Phase _phase = _Phase.setup;
  final _subjectController = TextEditingController();
  final _countController = TextEditingController();
  String _subject = '';
  int? _declaredCount;

  final List<_SessionItem> _items = [];
  int _nextItemId = 1;

  /// The examination's section rules — captured from the FIRST script that
  /// grades successfully, then reused for every following script in this
  /// session ("just pay attention to the marking instructions on the first
  /// page of the first script that you mark per cohort").
  MarkingRubric? _cohortRubric;

  /// A saved marking key whose subject matches this session's subject —
  /// auto-detected, sent to the AI as reference only, and shown to the
  /// teacher as a notice. Null when nothing matches (the normal pure-AI
  /// case).
  MarkingScheme? _referenceScheme;

  bool _marking = false;
  int _markDone = 0;
  int _markTotal = 0;

  /// True until the deep-link flow ([initialSource] / [pendingScripts]) has
  /// been kicked off once, right after the first load completes.
  bool _pendingInitialFlow = false;

  @override
  void initState() {
    super.initState();
    _pendingInitialFlow = widget.initialSource != null || widget.pendingScripts.isNotEmpty;
    if (_pendingInitialFlow) _phase = _Phase.session;
    _load();
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _countController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final catalog = await _repository.loadCatalog();
      final schemes = await _schemeRepository.loadCatalog();
      // "Only make available for marking only unmarked lists" — a script
      // that's already been graded or reviewed is not offered again here.
      final eligible = catalog.scripts
          .where((s) =>
              s.schemeId != null &&
              !s.photosDiscarded &&
              s.status != MarkingScriptStatus.graded &&
              s.status != MarkingScriptStatus.reviewed)
          .toList()
        ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      if (!mounted) return;
      setState(() {
        _eligibleScripts = eligible;
        _schemes = schemes;
        _recomputeReferenceScheme();
        _loading = false;
      });
      if (_pendingInitialFlow) {
        _pendingInitialFlow = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => _runInitialFlow());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load scripts: $error';
        _loading = false;
      });
    }
  }

  MarkingScheme? _schemeFor(MarkingScript script) {
    for (final s in _schemes.schemes) {
      if (s.id == script.schemeId) return s;
    }
    return null;
  }

  // -------------------------------------------------------------------
  // Deep-link entry (dropdown source / "Concise Marker" in the key picker)
  // -------------------------------------------------------------------
  Future<void> _runInitialFlow() async {
    if (!await _ensureSubject()) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    if (widget.pendingScripts.isNotEmpty) {
      await _addPendingScripts();
    } else if (widget.initialSource case final source?) {
      switch (source) {
        case ConciseMarkingSource.device:
          await _addFromCameraOrDevice(fromDevice: true);
        case ConciseMarkingSource.camera:
          await _addFromCameraOrDevice(fromDevice: false);
        case ConciseMarkingSource.queue:
          await _addFromQueue();
      }
    }
  }

  /// Concise Marking always needs a subject/course name on record (for the
  /// marked report and the cohort score list). Asks once, up front, then
  /// never again this session.
  Future<bool> _ensureSubject() async {
    if (_subject.trim().isNotEmpty) return true;
    final seed = widget.pendingScripts.isNotEmpty
        ? widget.pendingScripts.first.subjectName
        : (_eligibleScripts.isNotEmpty ? _eligibleScripts.first.subjectName : '');
    final controller = TextEditingController(text: seed.trim() == 'Unknown subject' ? '' : seed.trim());
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Subject / course name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. History, Form 4'),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()), child: const Text('Continue')),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return false;
    if (mounted) {
      setState(() {
        _subject = result;
        _recomputeReferenceScheme();
      });
    }
    return true;
  }

  /// Finds a saved marking key whose subject matches this session's
  /// subject — used only as AI reference, never as the authority.
  void _recomputeReferenceScheme() {
    final subj = _subject.trim().toLowerCase();
    if (subj.isEmpty) {
      _referenceScheme = null;
      return;
    }
    MarkingScheme? best;
    for (final s in _schemes.schemes) {
      final ss = s.subjectName.trim().toLowerCase();
      if (ss.isEmpty) continue;
      if (ss == subj || ss.contains(subj) || subj.contains(ss)) {
        best = s;
        break;
      }
    }
    _referenceScheme = best;
  }

  Future<void> _addPendingScripts() async {
    if (widget.pendingScripts.isEmpty) return;
    final added = {for (final i in _items) i.script.id};
    for (final raw in widget.pendingScripts) {
      if (added.contains(raw.id)) continue;
      setState(() => _items.add(_SessionItem(
            id: _nextItemId++,
            script: raw,
            candidateName: raw.fullName,
            referenceScheme: _schemeFor(raw) ?? _referenceScheme,
          )));
    }
  }

  // -------------------------------------------------------------------
  // Adding scripts to the session
  // -------------------------------------------------------------------
  Future<void> _showAddSources() async {
    if (!await _ensureSubject() || !mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Add script(s) to this session', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Upload from device'),
              subtitle: const Text('Pick page images already on this phone'),
              onTap: () => Navigator.of(sheetContext).pop('device'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Upload from camera'),
              subtitle: const Text('Photograph a script now'),
              onTap: () => Navigator.of(sheetContext).pop('camera'),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_check_outlined),
              title: const Text('Upload a list from queued lists'),
              subtitle: const Text('Unmarked scripts already linked to a marking key'),
              onTap: () => Navigator.of(sheetContext).pop('queue'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'queue':
        await _addFromQueue();
      case 'device':
        await _addFromCameraOrDevice(fromDevice: true);
      case 'camera':
        await _addFromCameraOrDevice(fromDevice: false);
    }
  }

  Future<void> _addFromQueue() async {
    if (!await _ensureSubject() || !mounted) return;
    final alreadyAdded = {for (final i in _items) i.script.id};
    final available = _eligibleScripts.where((s) => !alreadyAdded.contains(s.id)).toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No unmarked queued scripts to add. Queue a script against a marking key first, '
              'or use "Upload from device / camera".'),
        ),
      );
      return;
    }
    // Grouped by marking key — each key's queued batch is one "list".
    final byScheme = <String, List<MarkingScript>>{};
    for (final s in available) {
      byScheme.putIfAbsent(_schemeFor(s)?.title ?? s.subjectName, () => []).add(s);
    }
    final selected = <String>{};
    final picked = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setSheet) => AlertDialog(
          title: const Text('Add an unmarked list'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final entry in byScheme.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(entry.key, style: Theme.of(dialogContext).textTheme.labelLarge),
                        ),
                        TextButton(
                          onPressed: () => setSheet(() {
                            final ids = entry.value.map((s) => s.id);
                            final allIn = ids.every(selected.contains);
                            for (final id in ids) {
                              allIn ? selected.remove(id) : selected.add(id);
                            }
                          }),
                          child: Text(entry.value.every((s) => selected.contains(s.id)) ? 'None' : 'All'),
                        ),
                      ],
                    ),
                  ),
                  for (final s in entry.value)
                    CheckboxListTile(
                      dense: true,
                      value: selected.contains(s.id),
                      title: Text(s.fullName),
                      subtitle: Text(s.status.label),
                      onChanged: (v) => setSheet(() => v == true ? selected.add(s.id) : selected.remove(s.id)),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(
              onPressed: selected.isEmpty ? null : () => Navigator.of(dialogContext).pop(true),
              child: Text('Add ${selected.length}'),
            ),
          ],
        ),
      ),
    );
    if (picked != true) return;
    for (final s in available.where((s) => selected.contains(s.id))) {
      setState(() => _items.add(_SessionItem(
            id: _nextItemId++,
            script: s,
            candidateName: s.fullName,
            referenceScheme: _schemeFor(s) ?? _referenceScheme,
          )));
    }
  }

  Future<void> _addFromCameraOrDevice({required bool fromDevice}) async {
    List<File>? initialFiles;
    if (fromDevice) {
      final results = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png']);
      if (!mounted || results.isEmpty) return;
      initialFiles = [for (final f in results) if (f.path != null) File(f.path!)];
      if (initialFiles.isEmpty) return;
    }

    // BurstCaptureScreen runs the same details form (candidate name,
    // gender, subject/grade) and save-and-copy the rest of Scan Marker
    // uses — for camera it opens the camera, for device it takes the
    // images we just picked. It hands back a saved MarkingScript.
    final script = await Navigator.of(context).push<MarkingScript>(
      MaterialPageRoute(
        builder: (_) => BurstCaptureScreen(repository: _repository, initialPageFiles: initialFiles),
      ),
    );
    if (!mounted || script == null) return;

    final questionPaperFiles = await _maybeCaptureQuestionPaper(fromDevice: fromDevice);
    if (!mounted) return;

    await _load();
    if (!mounted) return;
    setState(() => _items.add(_SessionItem(
          id: _nextItemId++,
          script: script,
          candidateName: script.fullName,
          referenceScheme: _referenceScheme,
          questionPaperFiles: questionPaperFiles,
        )));
  }

  /// Optional per the answer to the design question (2026-09-10): default
  /// to script-only, but let the teacher attach the question paper /
  /// marking guide when the answer booklet doesn't carry the questions.
  Future<List<File>> _maybeCaptureQuestionPaper({required bool fromDevice}) async {
    final add = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add the question paper? (optional)'),
        content: const Text(
          'Only needed if the answers are in a separate booklet with no questions on them. Skip it if '
          'the script already shows the questions.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Skip')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Add it')),
        ],
      ),
    );
    if (add != true || !mounted) return const [];

    if (fromDevice) {
      final results = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png']);
      return [for (final f in results) if (f.path != null) File(f.path!)];
    }
    final captured = await Navigator.of(context).push<List<File>>(
      MaterialPageRoute(
        builder: (_) => const DocumentPagesCaptureScreen(
          title: 'Question paper',
          instructions: 'Photograph each page of the question paper / marking guide.',
          maxPages: 8,
        ),
      ),
    );
    return captured ?? const [];
  }

  Future<void> _editItemName(_SessionItem item) async {
    final controller = TextEditingController(text: item.candidateName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Candidate name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Mwansa Banda'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    setState(() => item.candidateName = name);
  }

  void _removeItem(_SessionItem item) {
    setState(() => _items.removeWhere((i) => i.id == item.id));
  }

  // -------------------------------------------------------------------
  // Marking
  // -------------------------------------------------------------------
  Future<void> _submitForMarking() async {
    final pending = _items.where((i) => i.status == _ItemStatus.pending || i.status == _ItemStatus.failed).toList();
    if (pending.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing left to mark — every script in this session is already marked.')),
      );
      return;
    }

    setState(() {
      _marking = true;
      _markDone = 0;
      _markTotal = pending.length;
    });

    for (final item in pending) {
      if (!mounted) return;
      setState(() => item.status = _ItemStatus.marking);
      try {
        if (!await MarkingEntitlementService.instance.canGradeAnother()) {
          setState(() {
            item.status = _ItemStatus.failed;
            item.error = "You've used this month's free AI gradings (the same allowance normal marking uses).";
          });
          break;
        }

        final pageFiles = await _repository.pageFilesFor(item.script);
        if (pageFiles.isEmpty) {
          throw const ConciseMarkingUnavailable(
            "This script's captured pages are no longer available (they may have been discarded to free storage).",
          );
        }

        final result = await _gradingService.grade(
          pageFiles: pageFiles,
          // Pure AI — never a strict key. Any saved key for this subject
          // rides along as reference only.
          referenceScheme: item.referenceScheme ?? _referenceScheme,
          questionPaperFiles: item.questionPaperFiles,
          subjectName: _subject,
          knownRubric: _cohortRubric,
        );
        await MarkingEntitlementService.instance.recordGradingUsed();
        _cohortRubric ??= result.rubric;
        final effectiveRubric = _cohortRubric ?? result.rubric;

        final score = const ConciseScoreCalculator().compute(
          answers: result.answers,
          sectionByLabel: result.sectionByLabel,
          rubric: effectiveRubric,
        );

        final updated = item.script.copyWith(
          status: MarkingScriptStatus.graded,
          gradedAnswers: result.answers,
          observations: result.observations,
          schemeId: item.referenceScheme?.id,
        );
        await _repository.update(updated);

        final tempDir = await getTemporaryDirectory();
        final outputDir = Directory('${tempDir.path}/concise_marking_${item.script.id}');
        if (!await outputDir.exists()) await outputDir.create(recursive: true);

        final subjectLabel = _subject.isNotEmpty ? _subject : 'script';
        final title = '${item.candidateName} - $subjectLabel';
        final annotated = await _annotationService.annotatePages(
          pageFiles: pageFiles,
          answers: result.answers,
          annotations: result.annotations,
          outputDir: outputDir,
          score: score,
        );
        final report = await _annotationService.generateMarkedReportPdf(
          score: score,
          observations: result.observations,
          title: title,
          subjectName: subjectLabel,
          studentName: item.candidateName,
          rubric: effectiveRubric,
          outputDir: outputDir,
        );
        final fallback = await _annotationService.generateFallbackReproduction(
          answers: result.answers,
          annotations: result.annotations,
          outputDir: outputDir,
          title: title,
        );

        if (!mounted) return;
        setState(() {
          item.script = updated;
          item.status = _ItemStatus.marked;
          item.score = score;
          item.annotatedPages = annotated;
          item.reportPdf = report;
          item.fallbackPdf = fallback;
          item.observations = result.observations;
          item.error = null;
        });
      } catch (error) {
        if (!mounted) return;
        setState(() {
          item.status = _ItemStatus.failed;
          item.error = '$error';
        });
      }
      if (mounted) setState(() => _markDone++);
    }

    if (!mounted) return;
    setState(() => _marking = false);
    await _load();
    if (!mounted) return;

    final markedNow = _items.where((i) => i.status == _ItemStatus.marked).length;
    final stillPending = _items.where((i) => i.status == _ItemStatus.pending || i.status == _ItemStatus.failed).length;
    if (markedNow > 0 && stillPending == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$markedNow script(s) marked. Ready to share the cohort score list.'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(label: 'Word / PDF', onPressed: _completeCohort),
        ),
      );
    }
  }

  Future<void> _openItemResult(_SessionItem item) async {
    if (item.status != _ItemStatus.marked) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _ConciseResultScreen(item: item, subject: _subject)),
    );
  }

  // -------------------------------------------------------------------
  // Complete the cohort — Word / PDF score list
  // -------------------------------------------------------------------
  Future<void> _completeCohort() async {
    final scored = _items.where((i) => i.score != null).toList();
    if (scored.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mark at least one script before completing the cohort.')),
      );
      return;
    }

    final format = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Cohort score list'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('docx'),
            child: const Text('Editable Word document (.docx)'),
          ),
          SimpleDialogOption(onPressed: () => Navigator.of(dialogContext).pop('pdf'), child: const Text('PDF')),
          SimpleDialogOption(onPressed: () => Navigator.of(dialogContext).pop('both'), child: const Text('Both')),
        ],
      ),
    );
    if (!mounted || format == null) return;

    try {
      final service = ConciseCohortScoreListDocumentService();
      final title = _subject.isNotEmpty ? _subject : 'Concise Marking cohort';
      final entries = [
        for (final i in scored)
          ConciseCohortEntry(
            candidateName: i.candidateName,
            score: i.score!,
            marked: i.status == _ItemStatus.marked,
          ),
      ];
      final files = <XFile>[];
      if (format == 'docx' || format == 'both') {
        final f = await service.generateDocx(cohortTitle: title, subjectName: _subject, entries: entries);
        files.add(XFile(f.path));
      }
      if (format == 'pdf' || format == 'both') {
        final f = await service.generatePdf(cohortTitle: title, subjectName: _subject, entries: entries);
        files.add(XFile(f.path));
      }
      if (!mounted || files.isEmpty) return;
      await SharePlus.instance.share(ShareParams(files: files, subject: '$title — cohort scores'));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not build the score list: $error')),
      );
    }
  }

  // -------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Concise Marking')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? _errorView(_loadError!, _load)
              : _phase == _Phase.setup
                  ? _buildSetup(context)
                  : _buildSession(context),
    );
  }

  Widget _errorView(String message, VoidCallback onRetry) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Try Again')),
            ],
          ),
        ),
      );

  Future<void> _pickSourceAndStart(String source) async {
    final typed = _subjectController.text.trim();
    if (_subject.isEmpty && typed.isNotEmpty) _subject = typed;
    final count = int.tryParse(_countController.text.trim());
    if (count != null && count > 0) _declaredCount = count;
    if (!await _ensureSubject()) return;
    if (!mounted) return;
    setState(() => _phase = _Phase.session);
    switch (source) {
      case 'device':
        await _addFromCameraOrDevice(fromDevice: true);
      case 'camera':
        await _addFromCameraOrDevice(fromDevice: false);
      case 'queue':
        await _addFromQueue();
    }
  }

  Widget _buildSetup(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Concise Marking — pure AI', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'No marking key needed. The AI reads the questions, their marks and the marking rules off each '
          'script (add a photo of the question paper if the answers are in a separate booklet), marks '
          'every answer, scores each paper out of 100, stamps the score and a short report on the '
          'script, and gives you a Word / PDF score list. If you have a saved key for this subject it is '
          'used as extra reference automatically.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _subjectController,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Subject / course name',
            hintText: 'e.g. History, Form 4',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _countController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'How many scripts will you mark this session? (optional)',
            hintText: 'You can still mark fewer or more',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),
        Text('Add scripts from…', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () => _pickSourceAndStart('device'),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Upload from device'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () => _pickSourceAndStart('camera'),
          icon: const Icon(Icons.photo_camera_outlined),
          label: const Text('Upload from camera'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _pickSourceAndStart('queue'),
          icon: const Icon(Icons.playlist_add_check_outlined),
          label: const Text('Upload a list from queued lists'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ],
    );
  }

  Widget _buildSession(BuildContext context) {
    final marked = _items.where((i) => i.status == _ItemStatus.marked).length;
    final pending = _items.where((i) => i.status == _ItemStatus.pending || i.status == _ItemStatus.failed).length;

    return Column(
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_subject, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  _declaredCount != null
                      ? 'Marked $marked of ${_declaredCount!} planned  ·  ${_items.length} in session'
                      : 'Marked $marked  ·  ${_items.length} in session',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  _referenceScheme != null
                      ? 'Pure AI marking · also using your saved key "${_referenceScheme!.title}" as reference'
                      : 'Pure AI marking — the AI reads the questions and marking rules off each script',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
                if (_cohortRubric case final r? when r.instructionsSummary.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('Rules from cover page: ${r.instructionsSummary}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                ],
                if (_marking) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: _markTotal == 0 ? null : _markDone / _markTotal),
                  const SizedBox(height: 4),
                  Text('Marking $_markDone of $_markTotal…', style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.note_add_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        const Text('No scripts added yet. Use "Add script(s)" below.', textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  itemCount: _items.length,
                  itemBuilder: (context, index) => _buildItemTile(context, _items[index]),
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _marking ? null : _showAddSources,
                        icon: const Icon(Icons.add),
                        label: const Text('Add script(s)'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (_marking || pending == 0) ? null : _submitForMarking,
                        icon: const Icon(Icons.grading),
                        label: Text('Submit $pending for marking'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: (_marking || marked == 0) ? null : _completeCohort,
                  icon: const Icon(Icons.flag_outlined),
                  label: const Text('Complete Marking Cohort (Word / PDF score list)'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItemTile(BuildContext context, _SessionItem item) {
    final (icon, iconColor) = switch (item.status) {
      _ItemStatus.pending => (Icons.hourglass_empty, Theme.of(context).colorScheme.outline),
      _ItemStatus.marking => (Icons.autorenew, Theme.of(context).colorScheme.primary),
      _ItemStatus.marked => (Icons.check_circle, Colors.green),
      _ItemStatus.failed => (Icons.error_outline, Theme.of(context).colorScheme.error),
    };
    final refLabel = item.referenceScheme != null
        ? 'AI + saved key "${item.referenceScheme!.title}"'
        : 'Pure AI marking';
    final subtitleParts = <String>[
      item.questionPaperFiles.isNotEmpty ? '$refLabel · question paper attached' : refLabel,
    ];
    if (item.status == _ItemStatus.marked && item.score != null) {
      subtitleParts.add('${item.score!.outOf100Label}  (${item.score!.rawFractionLabel} raw)');
    } else if (item.status == _ItemStatus.failed && item.error != null) {
      subtitleParts.add(item.error!);
    } else {
      subtitleParts.add(item.status.name);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(item.candidateName.isEmpty ? '(no name)' : item.candidateName),
        subtitle: Text(subtitleParts.join('\n')),
        isThreeLine: item.status == _ItemStatus.failed,
        onTap: item.status == _ItemStatus.marked ? () => _openItemResult(item) : null,
        trailing: _marking
            ? null
            : PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'name' => _editItemName(item),
                  'open' => _openItemResult(item),
                  'remove' => _removeItem(item),
                  _ => null,
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'name', child: Text('Edit name')),
                  if (item.status == _ItemStatus.marked)
                    const PopupMenuItem(value: 'open', child: Text('Open marked script')),
                  const PopupMenuItem(value: 'remove', child: Text('Remove from session')),
                ],
              ),
      ),
    );
  }
}

/// One marked script's result — the annotated pages, the brief report, and
/// the fallback page for answers that couldn't be located on the photo.
class _ConciseResultScreen extends StatelessWidget {
  const _ConciseResultScreen({required this.item, required this.subject});

  final _SessionItem item;
  final String subject;

  Future<void> _share() async {
    final files = <XFile>[
      for (final f in item.annotatedPages) XFile(f.path),
      if (item.reportPdf case final r?) XFile(r.path),
      if (item.fallbackPdf case final f?) XFile(f.path),
    ];
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files, subject: '${item.candidateName} — Concise Marking'));
  }

  @override
  Widget build(BuildContext context) {
    final score = item.score;
    return Scaffold(
      appBar: AppBar(title: Text(item.candidateName.isEmpty ? 'Marked script' : item.candidateName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (score != null) ...[
            Text('Score: ${score.outOf100Label}', style: Theme.of(context).textTheme.headlineSmall),
            Text('${score.rawFractionLabel} raw marks  ·  ${score.roundedPercent}%'
                '${score.rubricApplied ? '' : '  · no section rules found'}'),
            const SizedBox(height: 8),
            for (final s in score.sections)
              Text('• ${s.name}: ${ConciseScore.fmt(s.awarded)}/${ConciseScore.fmt(s.possible)}'
                  '${s.ignoredExcessQuestions > 0 ? '  (best ${s.countedQuestions} of ${s.countedQuestions + s.ignoredExcessQuestions})' : ''}'),
            const Divider(height: 24),
          ],
          Text(
            item.annotatedPages.isEmpty
                ? 'No answer could be confidently placed on the actual photo — see the generated page in the share bundle.'
                : '${item.annotatedPages.length} page(s) marked directly on the real photographed script. The score is stamped on page 1.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final page in item.annotatedPages)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(page)),
            ),
          if (item.reportPdf != null)
            const Card(
              child: ListTile(
                leading: Icon(Icons.assignment_outlined),
                title: Text('Performance report (PDF)'),
                subtitle: Text('Score breakdown by section + observations — travels with the marked script'),
              ),
            ),
          if (item.fallbackPdf != null)
            const Card(
              child: ListTile(
                leading: Icon(Icons.picture_as_pdf_outlined),
                title: Text('Answers marked on a generated page'),
                subtitle: Text('For answers not confidently locatable on the real photo'),
              ),
            ),
          if (item.observations.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Observations', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final o in item.observations.take(10))
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('•  $o')),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _share,
            icon: const Icon(Icons.share_outlined),
            label: const Text('Share marked script'),
          ),
        ),
      ),
    );
  }
}
