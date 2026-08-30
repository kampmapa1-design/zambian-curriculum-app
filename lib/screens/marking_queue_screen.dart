import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../models/syllabus_models.dart';
import '../services/batch_grading_runner.dart';
import '../services/marking_entitlement_service.dart';
import '../services/marking_gap_report_document_service.dart';
import '../services/marking_gap_report_service.dart';
import '../services/marking_grading_service.dart';
import '../services/marking_key_generation_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/pending_marking_key_draft_repository.dart';
import '../services/marking_script_repository.dart';
import 'burst_capture_screen.dart';
import 'capture_manual_scores_screen.dart';
import 'captured_list_analysis_intake_screen.dart';
import 'marking_analysis_screen.dart';
import 'marking_key_upload_flow.dart';
import 'marking_review_screen.dart';
import 'marking_scheme_list_screen.dart';
import 'script_batch_capture_screen.dart';

/// AI-Assisted Marking, Stage 2 hub — every captured script sits here,
/// grouped by status, until the teacher chooses to queue and process a
/// batch. Also carries Stage 4 (AI grading dispatch), Stage 5 (confidence
/// summary — see [_buildBatchSummary]), Stage 9 (access gating — see
/// [_processBatch]'s per-script entitlement check), and a first-pass
/// Stage 8 (retry handling — see [_processBatch]).
class MarkingQueueScreen extends StatefulWidget {
  const MarkingQueueScreen({super.key, this.repository, this.schemeRepository, this.gradingService});

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;
  final MarkingGradingService? gradingService;

  @override
  State<MarkingQueueScreen> createState() => _MarkingQueueScreenState();
}

class _MarkingQueueScreenState extends State<MarkingQueueScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final MarkingGradingService _gradingService = widget.gradingService ?? MarkingGradingService();
  late final MarkingGapReportService _gapReportService = MarkingGapReportService(schemeRepository: _schemeRepository);
  final MarkingGapReportDocumentService _gapReportDocumentService = MarkingGapReportDocumentService();

  /// How many marked (graded or reviewed) students form one "batch reports"
  /// checkpoint — see [_buildMarkedStudentsSummary]. Scripts are still
  /// captured and graded one at a time (or in whatever batch size the
  /// teacher chooses via "Process N script(s)") exactly as before; this
  /// only gates when the bundled batch-report action becomes available,
  /// as a natural class-sized review checkpoint.
  static const _reportBatchSize = 10;

  MarkingScriptCatalog _catalog = MarkingScriptCatalog.empty();
  MarkingSchemeCatalog _schemes = MarkingSchemeCatalog.empty();

  /// Remembered from the most recent script captured via "Upload Script"
  /// → camera (2026-08-31) — see ScriptBatchCaptureScreen.initialTemplate.
  /// Lets every subsequent script in the same marking session skip
  /// straight past the Subject & Grade and "which marking key" pickers,
  /// since those details don't change script to script within one
  /// session. Cleared by "Change subject / marking key" in the Upload
  /// Script menu, for the (rare) case a teacher genuinely needs to
  /// switch mid-session.
  SyllabusTemplate? _lastTemplate;
  MarkingScheme? _lastScheme;
  bool _loading = true;
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  // Batch-processing progress (Stage 4/8) — null when nothing is running.
  String? _processingBatchLabel;
  int _processedCount = 0;
  int _batchTotal = 0;

  int? _remainingFreeGradings;
  bool _generatingKey = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadRemainingFreeGradings();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForResumableMarkingKey());
  }

  /// A real fix for a real reported problem: Android can (and, on many
  /// devices, regularly does) kill this app's process in the background
  /// under memory pressure — losing everything an in-progress screen held
  /// only in memory. runMarkingKeyUploadFlow now persists the AI's
  /// derived marking key to disk the moment it succeeds, so even after a
  /// process kill mid-flow, that already-completed (and expensive) work
  /// isn't gone — offer to pick back up right after it instead.
  Future<void> _checkForResumableMarkingKey() async {
    final draft = await checkForResumableMarkingKeyDraft();
    if (draft == null || !mounted) return;
    final resume = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unfinished marking key found'),
        content: Text(
          'A marking key with ${draft.questions.length} question(s) was read but never saved '
          '(from ${_formatDraftTime(draft.savedAt)}). Continue with it?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Discard')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Continue')),
        ],
      ),
    );
    if (!mounted) return;
    if (resume != true) {
      await PendingMarkingKeyDraftRepository().clear();
      return;
    }
    final saved = await resumeMarkingKeyFlow(context: context, draft: draft, schemeRepository: _schemeRepository);
    if (saved != null) _load();
  }

  String _formatDraftTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} minute(s) ago';
    if (diff.inDays < 1) return '${diff.inHours} hour(s) ago';
    return '${diff.inDays} day(s) ago';
  }

  Future<void> _loadRemainingFreeGradings() async {
    final remaining = await MarkingEntitlementService.instance.remainingFreeGradings();
    if (mounted) setState(() => _remainingFreeGradings = remaining);
  }

  Future<void> _load() async {
    final catalog = await _repository.loadCatalog();
    final schemes = await _schemeRepository.loadCatalog();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _schemes = schemes;
      _loading = false;
    });
  }

  /// "Upload Marking Key" — reveals the device/camera choice directly
  /// (skipping "what do you have" — this button is explicitly for an
  /// already-answered marking key, sourceType always
  /// [MarkingKeySourceType.markingKey]) then runs the shared upload flow
  /// (also used by MarkingSchemeListScreen's "New Scheme").
  Future<void> _uploadMarkingKey(MarkingKeyUploadMethod method) async {
    final saved = await runMarkingKeyUploadFlow(
      context: context,
      sourceType: MarkingKeySourceType.markingKey,
      method: method,
      schemeRepository: _schemeRepository,
      onLoadingChanged: (loading) {
        if (mounted) setState(() => _generatingKey = loading);
      },
    );
    if (saved != null) _load();
  }

  /// "Upload Script" → "Upload from device" — one or more page images
  /// already on the device (a script scanned/photographed elsewhere and
  /// downloaded, or received via WhatsApp/email), fed into the same
  /// details-form + save flow BurstCaptureScreen already uses for camera
  /// capture, just skipping the camera itself.
  Future<void> _uploadScriptFromDevice() async {
    final results = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png'],
    );
    if (results.isEmpty || !mounted) return;

    final files = [for (final f in results) if (f.path != null) File(f.path!)];
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read the selected file(s).')),
      );
      return;
    }

    final result = await Navigator.of(context).push<MarkingScript>(
      MaterialPageRoute(builder: (_) => BurstCaptureScreen(repository: _repository, initialPageFiles: files)),
    );
    if (result != null) _load();
  }

  /// "Upload Script" → "Upload through camera" — the new continuous
  /// batch-capture flow (many scripts in one session, offline until
  /// explicitly confirmed) rather than BurstCaptureScreen's one-at-a-time
  /// flow.
  Future<void> _batchCaptureScripts() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScriptBatchCaptureScreen(
          repository: _repository,
          schemeRepository: _schemeRepository,
          gradingService: _gradingService,
          initialTemplate: _lastTemplate,
          initialScheme: _lastScheme,
          onSetupComplete: (template, scheme) => setState(() {
            _lastTemplate = template;
            _lastScheme = scheme;
          }),
        ),
      ),
    );
    _load();
    _loadRemainingFreeGradings();
  }

  /// Clears the remembered subject/grade/marking-key so the next "Upload
  /// Script" asks again — for the rare case a teacher genuinely needs to
  /// switch mid-session (see [_lastTemplate]'s doc).
  void _changeRememberedSubjectScheme() => setState(() {
        _lastTemplate = null;
        _lastScheme = null;
      });

  /// "Capture Manual Scores" — for teachers who mark entirely by hand:
  /// photograph a handwritten list (any pattern/table) and get back an
  /// editable Word document reproducing it. Self-contained — nothing
  /// here touches this screen's own state, so no _load() needed after.
  Future<void> _captureManualScores() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CaptureManualScoresScreen()),
    );
  }

  /// "Analyze Results" — the 4th hub action. First asks which source to
  /// analyze: a fresh photo of an already-completed results list (not
  /// tied to this app's own grading pipeline at all), or scripts already
  /// marked/reviewed through the app.
  Future<void> _analyzeResults() async {
    final choice = await showDialog<_AnalyzeSource>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Analyze Results'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_AnalyzeSource.captureOnPaper),
            child: const Row(
              children: [
                Icon(Icons.camera_alt_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Capture List On Paper?')),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_AnalyzeSource.previousScripts),
            child: const Row(
              children: [
                Icon(Icons.fact_check_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('List of previously completed Scripts?')),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == _AnalyzeSource.captureOnPaper) {
      final scheme = await Navigator.of(context).push<MarkingScheme>(
        MaterialPageRoute(
          builder: (_) => CapturedListAnalysisIntakeScreen(schemeRepository: _schemeRepository, scriptRepository: _repository),
        ),
      );
      if (scheme == null || !mounted) return;
      await _load();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MarkingAnalysisScreen(scheme: scheme, scriptRepository: _repository)),
      );
      return;
    }

    if (_schemes.schemes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No marking schemes yet — upload or build one first.')),
      );
      return;
    }

    final scheme = _schemes.schemes.length == 1
        ? _schemes.schemes.single
        : await showDialog<MarkingScheme>(
            context: context,
            builder: (dialogContext) => SimpleDialog(
              title: const Text('Analyze results for which marking key?'),
              children: [
                for (final s in _schemes.schemes)
                  SimpleDialogOption(
                    onPressed: () => Navigator.of(dialogContext).pop(s),
                    child: Text(s.title),
                  ),
              ],
            ),
          );
    if (scheme == null || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MarkingAnalysisScreen(scheme: scheme, scriptRepository: _repository)),
    );
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(MarkingScript script) {
    setState(() {
      if (_selectedIds.contains(script.id)) {
        _selectedIds.remove(script.id);
      } else {
        _selectedIds.add(script.id);
      }
    });
  }

  /// Queuing links each selected script to one marking scheme — a "batch"
  /// (Stage 2/4) is scripts from the same assessment, graded against the
  /// same scheme, so the link has to exist before there's anything to
  /// queue for.
  Future<void> _queueSelected() async {
    if (_schemes.schemes.isEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('No marking scheme yet'),
          content: const Text(
            'Queuing a script links it to a marking scheme, so grading knows what to check each answer '
            'against. Build one first.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Build One')),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MarkingSchemeListScreen()));
        await _load();
      }
      return;
    }

    final scheme = await showDialog<MarkingScheme>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Which marking scheme is this batch for?'),
        children: [
          for (final s in _schemes.schemes)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(s),
              child: Text('${s.title} (${s.questions.length} question(s))'),
            ),
        ],
      ),
    );
    if (scheme == null) return;

    final scripts = _catalog.scripts.where((s) => _selectedIds.contains(s.id));
    for (final script in scripts) {
      await _repository.update(script.copyWith(status: MarkingScriptStatus.queued, schemeId: scheme.id));
    }
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${scripts.length} script(s) queued against "${scheme.title}".')),
    );
  }

  /// Stage 4 dispatch + a first-pass Stage 8, via the shared
  /// [runBatchGrading] runner (also used by ScriptBatchCaptureScreen's
  /// "Mark all scripts?" confirmation, so both paths behave identically).
  ///
  /// The original spec's "retry via the fallback provider" isn't possible
  /// yet — this app doesn't have a second live provider (see the
  /// Cloud Function's own comment) — so this retries on the same
  /// provider instead. Worth revisiting once a real second provider
  /// exists.
  Future<void> _processBatch(String schemeId) async {
    final scheme = _schemes.schemes.firstWhere((s) => s.id == schemeId);
    final batch = _catalog.scripts.where((s) => s.status == MarkingScriptStatus.queued && s.schemeId == schemeId).toList();
    if (batch.isEmpty) return;

    setState(() {
      _processingBatchLabel = scheme.title;
      _processedCount = 0;
      _batchTotal = batch.length;
    });

    var ranOutOfFreeGradings = false;
    await runBatchGrading(
      scripts: batch,
      scheme: scheme,
      repository: _repository,
      gradingService: _gradingService,
      onProgress: (done, total) {
        if (mounted) setState(() => _processedCount = done);
      },
      onOutOfFreeGradings: () => ranOutOfFreeGradings = true,
    );

    if (ranOutOfFreeGradings && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "You've used this month's free AI-graded scripts. The rest of this batch stays queued "
            'until next month (or an upgrade, once that\'s available).',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    }

    setState(() => _processingBatchLabel = null);
    await _load();
    await _loadRemainingFreeGradings();
  }

  /// Stage 8 — the other half of retry handling: after the automatic
  /// double-attempt in [_processBatch] fails, a script lands in
  /// [MarkingScriptStatus.needsRetry] and stays there until a teacher asks
  /// for another attempt. Puts it back to [MarkingScriptStatus.queued]
  /// (keeping its scheme link) so the next "Process" run for that scheme
  /// picks it up again alongside anything else queued.
  Future<void> _retryScript(MarkingScript script) async {
    await _repository.update(script.copyWith(status: MarkingScriptStatus.queued, clearLastError: true));
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Moved back to queued — process its batch again to retry.')),
    );
  }

  /// Stage H — irreversible (see MarkingScriptRepository.discardPhotos'
  /// own doc), so this confirms explicitly and states plainly what stays
  /// and what goes, rather than a generic "are you sure?".
  Future<void> _discardPhotos(MarkingScript script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard captured photos?'),
        content: Text(
          "${script.fullName}'s ${script.pageCount} captured page image(s) will be permanently deleted to "
          'free up storage. The grades, transcriptions, and AI observations already recorded for this '
          'script are kept and remain fully viewable — only the photos themselves are removed.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Discard Photos')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.discardPhotos(script);
    _load();
  }

  Future<void> _deleteScript(MarkingScript script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this script?'),
        content: Text('${script.fullName} — Script ${script.scriptNumber} (${script.pageCount} page(s)) '
            'will be permanently deleted, including its captured pages.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.remove(script);
    _load();
  }

  /// Opens [script] for review, then — as long as each screen is left via
  /// a real Confirm & Finish, not by backing out — keeps opening whatever
  /// [MarkingReviewScreen] hands back as the next script to mark
  /// (2026-08-31), so a teacher reviews a whole batch back-to-back
  /// without returning here in between. [_load] only runs once, after
  /// the loop actually ends, so the queue never shows stale data from
  /// partway through a chain.
  Future<void> _openScript(MarkingScript script) async {
    if (script.status != MarkingScriptStatus.graded && script.status != MarkingScriptStatus.reviewed) return;

    // The rest of this scheme's still-graded scripts, in the same order
    // the "Marked Students" list uses — computed once up front so the
    // chain doesn't shift under the teacher's feet if something else
    // changes the underlying data mid-review.
    final queue = (_byStatus[MarkingScriptStatus.graded] ?? const <MarkingScript>[])
        .where((s) => s.schemeId == script.schemeId && s.id != script.id)
        .toList()
      ..sort((a, b) => a.scriptNumber.compareTo(b.scriptNumber));

    MarkingScript? current = script;
    var remaining = queue;
    while (current != null) {
      final scheme = current.schemeId == null
          ? null
          : _schemes.schemes.where((s) => s.id == current!.schemeId).cast<MarkingScheme?>().firstWhere((s) => true, orElse: () => null);
      final next = remaining.isEmpty ? null : remaining.first;
      final rest = remaining.isEmpty ? remaining : remaining.skip(1).toList();

      final result = await Navigator.of(context).push<MarkingScript?>(
        MaterialPageRoute(
          builder: (_) => MarkingReviewScreen(
            script: current!,
            scheme: scheme,
            repository: _repository,
            nextInQueue: next,
            remainingAfterNext: rest.length,
          ),
        ),
      );
      if (!mounted) return;
      current = result;
      remaining = rest;
    }
    _load();
  }

  /// Every graded-or-reviewed script — the "Marked Students" list. Sorted
  /// by surname (the app's usual convention, see MarkingScript's own doc)
  /// so the growing list reads like a class register.
  List<MarkingScript> get _markedScripts {
    final scripts = <MarkingScript>[
      ...(_byStatus[MarkingScriptStatus.graded] ?? const []),
      ...(_byStatus[MarkingScriptStatus.reviewed] ?? const []),
    ];
    scripts.sort((a, b) => a.surname.toLowerCase().compareTo(b.surname.toLowerCase()));
    return scripts;
  }

  /// "Report on [Name]" for one script — the present/missing comparison
  /// against the marking key, generated from data already produced by
  /// grading (no new AI call) and shared as an editable Word document.
  /// Purely additive: does not touch the existing marks/confidence review
  /// flow (MarkingReviewScreen) at all.
  Future<void> _viewGapReport(MarkingScript script) async {
    try {
      final report = await _gapReportService.build(script);
      final file = await _gapReportDocumentService.generateDocx(report);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'Report on ${report.studentName}'),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not build this report: $error')),
      );
    }
  }

  /// The batch-reports checkpoint action — bundles every marked student's
  /// report into one share action, available once [_markedScripts] has
  /// reached a multiple of [_reportBatchSize].
  Future<void> _shareBatchReports() async {
    final scripts = _markedScripts;
    final files = <XFile>[];
    final failed = <String>[];
    for (final script in scripts) {
      try {
        final report = await _gapReportService.build(script);
        final file = await _gapReportDocumentService.generateDocx(report);
        files.add(XFile(file.path));
      } catch (_) {
        failed.add(script.fullName);
      }
    }
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No reports could be built.')),
      );
      return;
    }
    await SharePlus.instance.share(
      ShareParams(files: files, subject: 'Marking reports (${files.length} student(s))'),
    );
    if (failed.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${failed.length} report(s) could not be built: ${failed.join(', ')}')),
      );
    }
  }

  Map<MarkingScriptStatus, List<MarkingScript>> get _byStatus {
    final grouped = <MarkingScriptStatus, List<MarkingScript>>{};
    for (final s in _catalog.scripts) {
      grouped.putIfAbsent(s.status, () => []).add(s);
    }
    return grouped;
  }

  /// Stage 5 — batch-level confidence summary, computed straight from
  /// Stage 4's stored results: how many answers across all graded-but-
  /// unreviewed scripts are ready to accept versus need a look.
  Widget? _buildConfidenceSummary(BuildContext context) {
    final graded = _byStatus[MarkingScriptStatus.graded] ?? const [];
    if (graded.isEmpty) return null;

    var high = 0, medium = 0, low = 0;
    for (final script in graded) {
      for (final a in script.gradedAnswers ?? const []) {
        switch (a.confidence) {
          case MarkingConfidence.high:
            high++;
          case MarkingConfidence.medium:
            medium++;
          case MarkingConfidence.low:
            low++;
        }
      }
    }
    final total = high + medium + low;
    if (total == 0) return null;

    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${graded.length} script(s) graded, awaiting review', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _confidenceChip(context, '$high ready to accept', Colors.green),
                _confidenceChip(context, '$medium need a glance', Colors.orange),
                _confidenceChip(context, '$low need review', Colors.red),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _confidenceChip(BuildContext context, String label, Color color) {
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: color.withValues(alpha: 0.15),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
      visualDensity: VisualDensity.compact,
    );
  }

  Color _statusColor(MarkingScriptStatus status, BuildContext context) => switch (status) {
        MarkingScriptStatus.captured => Theme.of(context).colorScheme.secondaryContainer,
        MarkingScriptStatus.queued => Theme.of(context).colorScheme.tertiaryContainer,
        MarkingScriptStatus.processing => Theme.of(context).colorScheme.primaryContainer,
        MarkingScriptStatus.graded => Colors.amber.shade200,
        MarkingScriptStatus.reviewed => Theme.of(context).colorScheme.surfaceContainerHighest,
        MarkingScriptStatus.needsRetry => Theme.of(context).colorScheme.errorContainer,
      };

  @override
  Widget build(BuildContext context) {
    final captured = _byStatus[MarkingScriptStatus.captured] ?? const [];
    final queuedByScheme = <String, List<MarkingScript>>{};
    for (final s in _byStatus[MarkingScriptStatus.queued] ?? const <MarkingScript>[]) {
      if (s.schemeId != null) queuedByScheme.putIfAbsent(s.schemeId!, () => []).add(s);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('AutoGrade'),
        actions: [
          IconButton(
            icon: const Icon(Icons.fact_check_outlined),
            tooltip: 'Marking Schemes',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MarkingSchemeListScreen()));
              _load();
            },
          ),
          if (captured.isNotEmpty)
            TextButton(
              onPressed: _toggleSelecting,
              child: Text(_selecting ? 'Cancel' : 'Select', style: const TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (!_selecting) _buildActionButtons(context),
                Expanded(
                  child: _catalog.scripts.isEmpty
                      ? _buildEmptyState(context)
                      : _buildQueueList(context, queuedByScheme),
                ),
              ],
            ),
      bottomNavigationBar: _selecting && _selectedIds.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _queueSelected,
                  icon: const Icon(Icons.playlist_add_check),
                  label: Text('Queue ${_selectedIds.length} Script(s) for Processing'),
                ),
              ),
            )
          : null,
    );
  }

  /// Left: "Upload Marking Key" and "Upload Script", each with a
  /// device/camera dropdown. Right: "Capture Manual Scores", for
  /// teachers who mark entirely by hand.
  Widget _buildActionButtons(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              children: [
                _buildDropdownActionButton(
                  context,
                  label: 'Upload Marking Key',
                  icon: Icons.fact_check_outlined,
                  busy: _generatingKey,
                  items: const [
                    PopupMenuItem(value: 'device', child: Text('Upload from device')),
                    PopupMenuItem(value: 'camera', child: Text('Upload through camera')),
                  ],
                  onSelected: (value) => _uploadMarkingKey(
                    value == 'device' ? MarkingKeyUploadMethod.uploadFromDevice : MarkingKeyUploadMethod.camera,
                  ),
                ),
                const SizedBox(height: 8),
                _buildDropdownActionButton(
                  context,
                  label: 'Upload Script',
                  icon: Icons.description_outlined,
                  items: [
                    const PopupMenuItem(value: 'device', child: Text('Upload from device')),
                    const PopupMenuItem(value: 'camera', child: Text('Upload through camera')),
                    if (_lastTemplate != null)
                      PopupMenuItem(
                        value: 'change',
                        child: Text('Change subject / marking key (currently: ${_lastTemplate!.subject.name})'),
                      ),
                  ],
                  onSelected: (value) => switch (value) {
                    'device' => _uploadScriptFromDevice(),
                    'change' => _changeRememberedSubjectScheme(),
                    _ => _batchCaptureScripts(),
                  },
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              children: [
                OutlinedButton.icon(
                  onPressed: _captureManualScores,
                  icon: const Icon(Icons.edit_note_outlined),
                  label: const Text('Capture Manual Scores', textAlign: TextAlign.center),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    minimumSize: const Size.fromHeight(0),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _analyzeResults,
                  icon: const Icon(Icons.query_stats_outlined),
                  label: const Text('Analyze Results', textAlign: TextAlign.center),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    minimumSize: const Size.fromHeight(0),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A button that, when tapped, "reveals" its two options as a dropdown
  /// (PopupMenuButton) — the Flutter-native equivalent of the requested
  /// "click and it reveals two working option buttons in a drop-down
  /// list".
  Widget _buildDropdownActionButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required List<PopupMenuEntry<String>> items,
    required ValueChanged<String> onSelected,
    bool busy = false,
  }) {
    return PopupMenuButton<String>(
      enabled: !busy,
      itemBuilder: (context) => items,
      onSelected: onSelected,
      child: IgnorePointer(
        child: FilledButton.icon(
          onPressed: () {},
          icon: busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon),
          label: Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
        ),
      ),
    );
  }

  /// "Marked Students" — the growing list of graded/reviewed scripts for
  /// this device, with a per-student report action always available, and
  /// a bundled "batch reports" checkpoint that lights up once a multiple
  /// of [_reportBatchSize] students have been marked.
  Widget _buildMarkedStudentsSummary(BuildContext context) {
    final scripts = _markedScripts;
    final count = scripts.length;
    final toNextCheckpoint = _reportBatchSize - (count % _reportBatchSize);
    final atCheckpoint = count % _reportBatchSize == 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.groups_outlined, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Marked Students ($count)', style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              atCheckpoint
                  ? 'Batch reports ready for these $count student(s).'
                  : '$toNextCheckpoint more to reach the next batch-reports checkpoint (every $_reportBatchSize).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (atCheckpoint)
              OutlinedButton.icon(
                onPressed: _shareBatchReports,
                icon: const Icon(Icons.summarize_outlined),
                label: Text('Share Reports for All $count Student(s)'),
              ),
            const SizedBox(height: 8),
            ...scripts.map(
              (script) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline, size: 20),
                title: Text(script.fullName),
                subtitle: Text(
                  '${script.subjectName} · ${script.gradeName}'
                  '${script.classLevel.isNotEmpty ? ' · ${script.classLevel}' : ''}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.description_outlined),
                  tooltip: 'Report on ${script.fullName}',
                  onPressed: () => _viewGapReport(script),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.document_scanner_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text(
              'No scripts captured yet. Use "Upload Script" above to photograph or upload a student\'s '
              'answer script — entirely offline.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueList(BuildContext context, Map<String, List<MarkingScript>> queuedByScheme) {
    final byStatus = _byStatus;
    final order = [
      MarkingScriptStatus.needsRetry,
      MarkingScriptStatus.processing,
      MarkingScriptStatus.graded,
      MarkingScriptStatus.queued,
      MarkingScriptStatus.captured,
      MarkingScriptStatus.reviewed,
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        if (_remainingFreeGradings case final remaining?)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              remaining > 0
                  ? '$remaining free AI-graded script(s) left this month.'
                  : "You've used this month's free AI-graded scripts — more become available next month.",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: remaining > 0 ? null : Theme.of(context).colorScheme.error,
                  ),
            ),
          ),
        if (_buildConfidenceSummary(context) case final summary?) summary,
        if (_markedScripts.isNotEmpty) _buildMarkedStudentsSummary(context),
        if (_processingBatchLabel case final label?)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Grading "$label"… ($_processedCount of $_batchTotal)'),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: _batchTotal == 0 ? null : _processedCount / _batchTotal),
                ],
              ),
            ),
          ),
        for (final status in order)
          if (byStatus[status]?.isNotEmpty ?? false) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 8),
              child: Text(
                '${status.label} (${byStatus[status]!.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (status == MarkingScriptStatus.queued)
              for (final entry in queuedByScheme.entries) ...[
                if (_processingBatchLabel == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      onPressed: () => _processBatch(entry.key),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(
                        'Process ${entry.value.length} script(s) — '
                        '${_schemes.schemes.where((s) => s.id == entry.key).map((s) => s.title).firstOrNull ?? 'Unknown scheme'}',
                      ),
                    ),
                  ),
                for (final script in entry.value) _buildScriptTile(context, script),
              ]
            else
              for (final script in byStatus[status]!) _buildScriptTile(context, script),
          ],
      ],
    );
  }

  Widget _buildScriptTile(BuildContext context, MarkingScript script) {
    final selectable = _selecting && script.status == MarkingScriptStatus.captured;
    final selected = _selectedIds.contains(script.id);
    final openable = script.status == MarkingScriptStatus.graded || script.status == MarkingScriptStatus.reviewed;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _statusColor(script.status, context),
          child: Text('${script.scriptNumber}', style: const TextStyle(fontSize: 13)),
        ),
        // First name on top, surname below.
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(script.firstName),
            Text(script.surname, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        subtitle: Text(
          '${script.subjectName} · ${script.gradeName} · ${script.gender.label}'
          '${script.genderConfirmed ? '' : ' (unconfirmed)'}\n'
          '${script.pageCount} page(s)${script.photosDiscarded ? ' (discarded)' : ''}'
          '${script.studentIdNumber != null ? ' · ID ${script.studentIdNumber}' : ''}'
          '${script.classLevel.isNotEmpty ? ' · ${script.classLevel}' : ''}'
          ' · ${script.status.label}'
          '${script.status == MarkingScriptStatus.needsRetry && script.lastError != null ? ' — ${script.lastError}' : ''}',
        ),
        isThreeLine: true,
        onTap: selectable
            ? () => _toggleSelected(script)
            : openable
                ? () => _openScript(script)
                : null,
        trailing: selectable
            ? Checkbox(value: selected, onChanged: (_) => _toggleSelected(script))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (script.status == MarkingScriptStatus.needsRetry)
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Retry',
                      onPressed: () => _retryScript(script),
                    ),
                  if (script.status == MarkingScriptStatus.reviewed && !script.photosDiscarded)
                    IconButton(
                      icon: const Icon(Icons.image_not_supported_outlined),
                      tooltip: 'Discard photos (keep results)',
                      onPressed: () => _discardPhotos(script),
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: () => _deleteScript(script),
                  ),
                ],
              ),
      ),
    );
  }
}

enum _AnalyzeSource { captureOnPaper, previousScripts }
