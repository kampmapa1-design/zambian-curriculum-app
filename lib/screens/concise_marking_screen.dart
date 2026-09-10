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

/// "Concise Marking" (Scan Marker) — a whole marking SESSION for one exam:
/// the teacher says which subject and how many scripts, adds scripts from
/// the marking queue / device / camera, then presses "Submit for marking"
/// when ready. The engine reads the section rules off the FIRST script's
/// cover page once and reuses them for the rest, scores every paper out of
/// 100 with those "answer N of M per section" rules applied
/// deterministically ([ConciseScoreCalculator]), stamps the score + a
/// brief report onto each marked script, and on "Complete Marking Cohort"
/// hands back an editable Word / PDF list of names and scores.
///
/// The real ticks/crosses on the actual photographed pages
/// ([ScriptAnnotationService]) and the fallback generated page for answers
/// that couldn't be located are unchanged from the first version of this
/// feature — this rework adds the session, the rubric, and the totals.
class ConciseMarkingScreen extends StatefulWidget {
  const ConciseMarkingScreen({
    super.key,
    this.repository,
    this.schemeRepository,
    this.gradingService,
    this.annotationService,
  });

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;
  final ConciseMarkingService? gradingService;
  final ScriptAnnotationService? annotationService;

  @override
  State<ConciseMarkingScreen> createState() => _ConciseMarkingScreenState();
}

enum _Phase { setup, session }

enum _ItemStatus { pending, marking, marked, failed }

class _SessionItem {
  _SessionItem({required this.id, required this.script, required this.scheme, required this.candidateName});

  final int id;
  MarkingScript script;
  final MarkingScheme scheme;
  String candidateName;

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

  bool _marking = false;
  int _markDone = 0;
  int _markTotal = 0;

  @override
  void initState() {
    super.initState();
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
      final eligible = catalog.scripts.where((s) => s.schemeId != null && !s.photosDiscarded).toList()
        ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      if (!mounted) return;
      setState(() {
        _eligibleScripts = eligible;
        _schemes = schemes;
        _loading = false;
      });
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
  // Setup
  // -------------------------------------------------------------------
  void _startSession() {
    final subject = _subjectController.text.trim();
    if (subject.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the subject or course name for this session.')),
      );
      return;
    }
    final count = int.tryParse(_countController.text.trim());
    setState(() {
      _subject = subject;
      _declaredCount = (count != null && count > 0) ? count : null;
      _phase = _Phase.session;
    });
  }

  // -------------------------------------------------------------------
  // Adding scripts to the session
  // -------------------------------------------------------------------
  Future<void> _showAddSources() async {
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
              leading: const Icon(Icons.playlist_add_check_outlined),
              title: const Text('From the marking queue'),
              subtitle: const Text('Scripts already captured and linked to a marking key'),
              onTap: () => Navigator.of(sheetContext).pop('queue'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('From device'),
              subtitle: const Text('Pick page images already on this phone'),
              onTap: () => Navigator.of(sheetContext).pop('device'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('From camera'),
              subtitle: const Text('Photograph a script now'),
              onTap: () => Navigator.of(sheetContext).pop('camera'),
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
    final alreadyAdded = {for (final i in _items) i.script.id};
    final available = _eligibleScripts.where((s) => !alreadyAdded.contains(s.id)).toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No queued scripts left to add. Queue a script against a marking key first.')),
      );
      return;
    }
    final selected = <String>{};
    final picked = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setSheet) => AlertDialog(
          title: const Text('Add from marking queue'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final s in available)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(s.id),
                    title: Text(s.fullName),
                    subtitle: Text('${_schemeFor(s)?.title ?? s.subjectName} · ${s.status.label}'),
                    onChanged: (v) => setSheet(() => v == true ? selected.add(s.id) : selected.remove(s.id)),
                  ),
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
      final scheme = _schemeFor(s);
      if (scheme == null) continue;
      setState(() => _items.add(_SessionItem(id: _nextItemId++, script: s, scheme: scheme, candidateName: s.fullName)));
    }
  }

  Future<void> _addFromCameraOrDevice({required bool fromDevice}) async {
    if (_schemes.schemes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Build or upload a marking key first — Concise Marking needs one to score against.')),
      );
      return;
    }

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

    final scheme = await _pickScheme();
    if (!mounted || scheme == null) return;

    final linked = script.copyWith(status: MarkingScriptStatus.queued, schemeId: scheme.id);
    await _repository.update(linked);
    await _load();
    if (!mounted) return;
    setState(() => _items.add(
          _SessionItem(id: _nextItemId++, script: linked, scheme: scheme, candidateName: linked.fullName),
        ));
  }

  Future<MarkingScheme?> _pickScheme() async {
    if (_schemes.schemes.length == 1) return _schemes.schemes.single;
    return showDialog<MarkingScheme>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Which marking key is this script for?'),
        children: [
          for (final s in _schemes.schemes)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(s),
              child: Text('${s.title} (${s.questions.length} question(s))'),
            ),
        ],
      ),
    );
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
          scheme: item.scheme,
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
        );
        await _repository.update(updated);

        final tempDir = await getTemporaryDirectory();
        final outputDir = Directory('${tempDir.path}/concise_marking_${item.script.id}');
        if (!await outputDir.exists()) await outputDir.create(recursive: true);

        final title = '${item.candidateName} - ${item.scheme.title}';
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
          subjectName: _subject.isNotEmpty ? _subject : item.scheme.subjectName,
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
      final title = _subject.isNotEmpty ? _subject : scored.first.scheme.title;
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

  Widget _buildSetup(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Start a marking session', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Concise Marking reads the marking rules off the first script\'s cover page, applies each '
          'section\'s "answer N of M" rule, and scores every paper out of 100.',
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
            labelText: 'How many scripts will you mark this session?',
            hintText: 'Optional — you can still mark fewer or more',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _startSession,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start session'),
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
    final subtitleParts = <String>[item.scheme.title];
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
