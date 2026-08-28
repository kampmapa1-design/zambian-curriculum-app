import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/batch_grading_runner.dart';
import '../services/marking_entitlement_service.dart';
import '../services/marking_grading_service.dart';
import '../services/marking_key_generation_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import 'burst_capture_screen.dart';
import 'class_list_import_screen.dart';
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

  MarkingScriptCatalog _catalog = MarkingScriptCatalog.empty();
  MarkingSchemeCatalog _schemes = MarkingSchemeCatalog.empty();
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
        ),
      ),
    );
    _load();
    _loadRemainingFreeGradings();
  }

  /// "Capture Manual Scores" — for teachers who mark entirely by hand.
  Future<void> _captureManualScores() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClassListImportScreen(schemeRepository: _schemeRepository, scriptRepository: _repository),
      ),
    );
    _load();
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

  Future<void> _openScript(MarkingScript script) async {
    if (script.status != MarkingScriptStatus.graded && script.status != MarkingScriptStatus.reviewed) return;
    final scheme = script.schemeId == null
        ? null
        : _schemes.schemes.where((s) => s.id == script.schemeId).cast<MarkingScheme?>().firstWhere((s) => true, orElse: () => null);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MarkingReviewScreen(script: script, scheme: scheme, repository: _repository),
      ),
    );
    _load();
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
        title: const Text('AI-Assisted Marking'),
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
                  items: const [
                    PopupMenuItem(value: 'device', child: Text('Upload from device')),
                    PopupMenuItem(value: 'camera', child: Text('Upload through camera')),
                  ],
                  onSelected: (value) =>
                      value == 'device' ? _uploadScriptFromDevice() : _batchCaptureScripts(),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _captureManualScores,
              icon: const Icon(Icons.edit_note_outlined),
              label: const Text('Capture Manual Scores', textAlign: TextAlign.center),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
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
