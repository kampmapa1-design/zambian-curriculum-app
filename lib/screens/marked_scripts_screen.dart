import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/marked_results_list_repository.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import '../services/photo_batch_service.dart';
import 'consolidate_marked_scripts_screen.dart';
import 'marked_results_lists_screen.dart';
import 'marking_review_screen.dart';

/// AI-Assisted Marking — "View Marked Scripts" (2026-08-31), reachable
/// from the capture screen AND (2026-09-10, per explicit request — a real
/// reported gap: this screen's own select/consolidate/delete tools were
/// only reachable from inside a capture session, not from Scan Marker's
/// own home hub) a "Manage" button on MarkingQueueScreen's own "Marked
/// Students" summary. Shows every [MarkingScriptStatus.graded] (AI
/// marked, awaiting review) and [MarkingScriptStatus.reviewed] (already
/// confirmed) script across every scheme — unlike MarkingQueueScreen's
/// own per-scheme "next in queue" chaining, this is a flat, complete
/// list, since the point here is finding one specific script, not
/// working through a batch in order.
///
/// Tapping a script offers review it again (open MarkingReviewScreen,
/// editable either way), reprocess it (send back to AI grading), mark it
/// as reviewed directly without reopening the full review UI, or delete
/// it — always with a confirmation dialog first, naming the student and
/// page count, since it's irreversible (2026-09-10, per explicit request:
/// "the app ought to ask for confirmation before deleting a data entry of
/// a marked student"). Long-pressing a row (or the AppBar's checklist
/// icon) enters select mode, highlighting the row(s) ticked — from there,
/// an "Actions" button opens the full set for the whole selection at once
/// (2026-09-11, per explicit request — a real gap: select mode used to
/// offer only Delete and "New List"): review/edit (one script only),
/// reprocess with AI, share the photo batch (see [_sharePhotoBatchForSelected]),
/// move into a manually-curated list, or delete — every consequential one
/// confirms first.
///
/// Manual results lists (added 2026-09-02): select mode, then "New List"
/// moves the ticked scripts into a manually-curated, named list (see
/// marked_results_list.dart). A script that belongs to any list stops
/// appearing here, matching "gets moved to the new list" exactly; the
/// folder icon opens [MarkedResultsListsScreen] to see every list
/// created so far. Scores stay fully editable everywhere until a list
/// is exported/shared for the first time — see
/// MarkedResultsListDetailScreen._export and
/// MarkingReviewScreen.locked.
class MarkedScriptsScreen extends StatefulWidget {
  const MarkedScriptsScreen({
    super.key,
    this.repository,
    this.schemeRepository,
    this.listRepository,
    this.photoBatchService,
  });

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;
  final MarkedResultsListRepository? listRepository;
  final PhotoBatchService? photoBatchService;

  @override
  State<MarkedScriptsScreen> createState() => _MarkedScriptsScreenState();
}

class _MarkedScriptsScreenState extends State<MarkedScriptsScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final MarkedResultsListRepository _listRepository = widget.listRepository ?? MarkedResultsListRepository();
  late final PhotoBatchService _photoBatchService = widget.photoBatchService ?? PhotoBatchService();

  bool _loading = true;
  List<MarkingScript> _scripts = [];
  MarkingSchemeCatalog _schemes = MarkingSchemeCatalog.empty();

  bool _selectMode = false;
  final Set<String> _selectedIds = {};

  /// See MarkedResultsListDetailScreen's own doc comment on why this
  /// exists — same class of real, reported bug (an uncaught exception
  /// leaving `_loading` true forever, indistinguishable from "still
  /// working").
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final catalog = await _repository.loadCatalog();
      final schemes = await _schemeRepository.loadCatalog();
      final lists = await _listRepository.loadCatalog();
      final marked = catalog.scripts
          .where((s) => s.status == MarkingScriptStatus.graded || s.status == MarkingScriptStatus.reviewed)
          .where((s) => !lists.allScriptIds.contains(s.id))
          .toList()
        ..sort((a, b) {
          final bySurname = a.surname.toLowerCase().compareTo(b.surname.toLowerCase());
          return bySurname != 0 ? bySurname : a.firstName.toLowerCase().compareTo(b.firstName.toLowerCase());
        });
      if (!mounted) return;
      setState(() {
        _scripts = marked;
        _schemes = schemes;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load marked scripts: $error';
        _loading = false;
      });
    }
  }

  MarkingScheme? _schemeFor(MarkingScript script) {
    if (script.schemeId == null) return null;
    for (final s in _schemes.schemes) {
      if (s.id == script.schemeId) return s;
    }
    return null;
  }

  double? _percentFor(MarkingScript script) {
    final awarded = script.totalAwarded;
    final possible = script.totalPossible;
    if (awarded == null || possible == null || possible == 0) return null;
    return (awarded / possible) * 100;
  }

  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(String scriptId) {
    setState(() {
      if (_selectedIds.contains(scriptId)) {
        _selectedIds.remove(scriptId);
      } else {
        _selectedIds.add(scriptId);
      }
    });
  }

  /// Delete-with-confirmation for one marked script (2026-09-10, per
  /// explicit request: "highlightable, editable and even able to get
  /// deleted with confirmation... the app ought to ask for confirmation
  /// before deleting a data entry of a marked student"). Same dialog
  /// wording/pattern MarkingQueueScreen's own `_deleteScript` already uses
  /// for a captured-but-not-yet-marked script — irreversible, so the
  /// captured pages are named explicitly rather than just "this script".
  Future<void> _deleteScript(MarkingScript script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this script?'),
        content: Text(
          '${script.fullName} — Script ${script.scriptNumber} (${script.pageCount} page(s)) will be '
          'permanently deleted, including its captured pages and marks.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.remove(script);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted ${script.fullName}\'s script.')),
    );
    _load();
  }

  /// Bulk version of [_deleteScript] for select mode — one confirmation
  /// names how many, not each one individually.
  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final selected = _scripts.where((s) => _selectedIds.contains(s.id)).toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${selected.length} script(s)?'),
        content: const Text(
          'These scripts will be permanently deleted, including their captured pages and marks.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final script in selected) {
      await _repository.remove(script);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted ${selected.length} script(s).')),
    );
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
    _load();
  }

  Future<void> _createNewList() async {
    if (_selectedIds.isEmpty) return;
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New results list'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'List name', border: OutlineInputBorder(), hintText: 'e.g. "Term 1 Finals"'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(nameController.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;

    await _listRepository.create(name: name, scriptIds: _selectedIds.toList());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Created "$name" with ${_selectedIds.length} script(s) — moved off this list.')),
    );
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
    _load();
  }

  /// The full action set for ticked scripts (2026-09-11, per explicit
  /// request: "when names are ticked, the only option available is
  /// delete. Instead... the app should offer the options of review/edit,
  /// reprocess with AI, batch the processed pictures and selected scripts
  /// to be uploaded as a folder... or create a link... or permanently
  /// delete"). Mirrors [_openActions]'s single-script bottom sheet in
  /// spirit, scaled to a real selection: New List (existing), Review/Edit
  /// (only when exactly one script is ticked — a review screen is
  /// inherently one-script-at-a-time), Reprocess with AI, Share Photo
  /// Batch (reuses PhotoBatchService, same as CohortCompletionScreen's own
  /// "Share the Photo Batch", scoped to just this selection instead of a
  /// whole cohort), and Delete — every one of these confirms first except
  /// New List (already asks for a name, which is its own confirmation)
  /// and Review/Edit (non-destructive, opens a normal editable screen).
  Future<void> _openBulkActions() async {
    if (_selectedIds.isEmpty) return;
    final selected = _scripts.where((s) => _selectedIds.contains(s.id)).toList();
    final action = await showModalBottomSheet<_BulkAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('${selected.length} script(s) selected', style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_outlined),
              title: const Text('Create a new list'),
              subtitle: const Text('Move these into a manually-curated, named results list'),
              onTap: () => Navigator.of(sheetContext).pop(_BulkAction.newList),
            ),
            if (selected.length == 1)
              ListTile(
                leading: const Icon(Icons.rate_review_outlined),
                title: const Text('Review / edit'),
                subtitle: const Text('Open this script — every answer stays editable'),
                onTap: () => Navigator.of(sheetContext).pop(_BulkAction.review),
              ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Reprocess with AI'),
              subtitle: const Text("Send them back to AI grading — current marks stay until they're regraded"),
              onTap: () => Navigator.of(sheetContext).pop(_BulkAction.reprocess),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Share the photo batch'),
              subtitle: const Text('The captured pages behind these scripts — share the usual way, or get a link'),
              onTap: () => Navigator.of(sheetContext).pop(_BulkAction.photoBatch),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(sheetContext).colorScheme.error),
              title: Text('Delete', style: TextStyle(color: Theme.of(sheetContext).colorScheme.error)),
              subtitle: const Text('Permanently remove these scripts and their captured pages — asks to confirm first'),
              onTap: () => Navigator.of(sheetContext).pop(_BulkAction.delete),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _BulkAction.newList:
        await _createNewList();
      case _BulkAction.review:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MarkingReviewScreen(script: selected.single, scheme: _schemeFor(selected.single), repository: _repository),
          ),
        );
        _load();
      case _BulkAction.reprocess:
        await _reprocessSelected(selected);
      case _BulkAction.photoBatch:
        await _sharePhotoBatchForSelected(selected);
      case _BulkAction.delete:
        await _deleteSelected();
    }
  }

  /// Bulk reprocess — same real action as [_openActions]'s single-script
  /// "Reprocess with AI" (queue it for the next batch run), applied to
  /// every ticked script. Confirms first (per explicit request, applying
  /// this generally to a bulk action even though the single-script
  /// version doesn't — a wider blast radius warrants it) since it
  /// discards the current marks pending a fresh AI pass.
  Future<void> _reprocessSelected(List<MarkingScript> selected) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Reprocess ${selected.length} script(s)?'),
        content: const Text(
          "These will be sent back to AI grading — process the queue from Scan Marker's home screen to "
          'actually run it. Current marks stay in place until each one is regraded.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Reprocess')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final script in selected) {
      await _repository.update(script.copyWith(status: MarkingScriptStatus.queued, clearLastError: true));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Moved ${selected.length} script(s) back to queued.')),
    );
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
    _load();
  }

  /// "Batch the processed pictures and selected scripts to be uploaded as
  /// a folder on another online AI app or create a link" — same real
  /// mechanism as CohortCompletionScreen's own "Share the Photo Batch"
  /// (see PhotoBatchService), scoped to just the ticked scripts here
  /// instead of a whole cohort.
  Future<void> _sharePhotoBatchForSelected(List<MarkingScript> selected) async {
    try {
      final imageFiles = <File>[];
      for (final script in selected) {
        imageFiles.addAll(await _repository.pageFilesFor(script));
      }
      if (imageFiles.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No captured pages are available for the selected script(s) (photos may already have been discarded to free storage).')),
        );
        return;
      }

      final title = selected.length == 1 ? selected.single.fullName : '${selected.length} scripts';
      final pdf = await _photoBatchService.composePdf(imageFiles, title: title);
      if (!mounted) return;

      final choice = await showModalBottomSheet<_PhotoBatchShareAction>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  'Photo Batch — ${imageFiles.length} page(s) across ${selected.length} script(s)',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share via…'),
                subtitle: const Text('The usual sharing means — WhatsApp, email, Drive, and anything else installed'),
                onTap: () => Navigator.of(sheetContext).pop(_PhotoBatchShareAction.share),
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Get a shareable link'),
                subtitle: const Text('Paste it into another AI platform, or anywhere else — stays valid for 30 days'),
                onTap: () => Navigator.of(sheetContext).pop(_PhotoBatchShareAction.link),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (choice == null || !mounted) return;

      switch (choice) {
        case _PhotoBatchShareAction.share:
          await SharePlus.instance.share(ShareParams(files: [XFile(pdf.path)], subject: '$title — Photo Batch'));
        case _PhotoBatchShareAction.link:
          try {
            final url = await _photoBatchService.uploadAndGetLink(pdf);
            if (!mounted) return;
            await Clipboard.setData(ClipboardData(text: url));
            if (!mounted) return;
            await showDialog<void>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('Link copied'),
                content: SelectableText(url),
                actions: [
                  FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Done')),
                ],
              ),
            );
          } on PhotoBatchUnavailable catch (error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
          }
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not prepare the photo batch: $error')),
      );
    }
  }

  Future<void> _openActions(MarkingScript script) async {
    final scheme = _schemeFor(script);
    final action = await showModalBottomSheet<_ScriptAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(script.fullName, style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.rate_review_outlined),
              title: const Text('Review / edit'),
              subtitle: const Text('Open this script — every answer stays editable'),
              onTap: () => Navigator.of(sheetContext).pop(_ScriptAction.review),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Reprocess with AI'),
              subtitle: const Text("Send it back to AI grading — current marks stay until it's regraded"),
              onTap: () => Navigator.of(sheetContext).pop(_ScriptAction.reprocess),
            ),
            if (script.status != MarkingScriptStatus.reviewed)
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Mark as reviewed'),
                subtitle: const Text('Confirm the current AI marks as final, without reopening the full review'),
                onTap: () => Navigator.of(sheetContext).pop(_ScriptAction.markReviewed),
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(sheetContext).colorScheme.error),
              title: Text('Delete', style: TextStyle(color: Theme.of(sheetContext).colorScheme.error)),
              subtitle: const Text('Permanently remove this script and its captured pages — asks to confirm first'),
              onTap: () => Navigator.of(sheetContext).pop(_ScriptAction.delete),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _ScriptAction.review:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MarkingReviewScreen(script: script, scheme: scheme, repository: _repository),
          ),
        );
        _load();
      case _ScriptAction.reprocess:
        await _repository.update(script.copyWith(status: MarkingScriptStatus.queued, clearLastError: true));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Moved back to queued — process its batch again from the hub to reprocess it.')),
        );
        _load();
      case _ScriptAction.markReviewed:
        await _repository.update(script.copyWith(status: MarkingScriptStatus.reviewed));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Marked as reviewed.')),
        );
        _load();
      case _ScriptAction.delete:
        await _deleteScript(script);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode ? '${_selectedIds.length} selected' : 'Marked Scripts'),
        actions: [
          if (_selectMode) ...[
            // Real, reported gap (2026-09-11): this used to be two bare
            // icon buttons (Delete + "New List" text) — everything else a
            // ticked selection can do (review/edit, reprocess, share the
            // photo batch) had no way in at all. One "Actions" entry point
            // now opens the full set (see _openBulkActions's own doc
            // comment).
            TextButton.icon(
              onPressed: _selectedIds.isEmpty ? null : _openBulkActions,
              icon: const Icon(Icons.more_horiz),
              label: const Text('Actions'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          ] else ...[
            IconButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ConsolidateMarkedScriptsScreen()),
              ),
              icon: const Icon(Icons.merge_type),
              tooltip: 'Consolidate into a class\'s Broad Mark Sheet',
            ),
            IconButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => MarkedResultsListsScreen(listRepository: _listRepository)),
              ),
              icon: const Icon(Icons.folder_outlined),
              tooltip: 'My results lists',
            ),
            if (_scripts.isNotEmpty)
              IconButton(
                onPressed: _toggleSelectMode,
                icon: const Icon(Icons.checklist_outlined),
                tooltip: 'Select scripts to move into a list',
              ),
          ],
          if (_selectMode)
            IconButton(onPressed: _toggleSelectMode, icon: const Icon(Icons.close), tooltip: 'Cancel'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                        const SizedBox(height: 12),
                        Text(_loadError!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _load, child: const Text('Try Again')),
                      ],
                    ),
                  ),
                )
              : _scripts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.fact_check_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        const Text('No marked scripts yet.', textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _scripts.length,
                  itemBuilder: (context, index) {
                    final script = _scripts[index];
                    final scheme = _schemeFor(script);
                    final percent = _percentFor(script);
                    final reviewed = script.status == MarkingScriptStatus.reviewed;
                    final selected = _selectedIds.contains(script.id);
                    return ListTile(
                      leading: _selectMode
                          ? Checkbox(value: selected, onChanged: (_) => _toggleSelected(script.id))
                          : CircleAvatar(
                              backgroundColor: reviewed
                                  ? Theme.of(context).colorScheme.primaryContainer
                                  : Theme.of(context).colorScheme.surfaceContainerHighest,
                              child: Icon(reviewed ? Icons.check : Icons.hourglass_top_outlined, size: 18),
                            ),
                      title: Text(script.fullName),
                      subtitle: Text(
                        '${scheme?.title ?? script.subjectName} · ${script.gradeName}'
                        '${script.classLevel.isEmpty ? '' : ' · ${script.classLevel}'}'
                        '\n${reviewed ? 'Reviewed' : 'Graded — needs review'}',
                      ),
                      isThreeLine: true,
                      trailing: percent == null ? null : Text('${percent.toStringAsFixed(1)}%', style: const TextStyle(fontWeight: FontWeight.bold)),
                      selected: selected,
                      selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                      onTap: _selectMode ? () => _toggleSelected(script.id) : () => _openActions(script),
                      onLongPress: _selectMode
                          ? null
                          : () {
                              // Long-press to enter select mode already
                              // highlighted on this one entry (2026-09-10,
                              // per explicit request: "highlightable") —
                              // quicker than tapping the AppBar checklist
                              // icon first, then finding this row again.
                              setState(() {
                                _selectMode = true;
                                _selectedIds.add(script.id);
                              });
                            },
                    );
                  },
                ),
    );
  }
}

enum _ScriptAction { review, reprocess, markReviewed, delete }

enum _BulkAction { newList, review, reprocess, photoBatch, delete }

enum _PhotoBatchShareAction { share, link }
