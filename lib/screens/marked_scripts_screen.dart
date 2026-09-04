import 'package:flutter/material.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/marked_results_list_repository.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import 'consolidate_marked_scripts_screen.dart';
import 'marked_results_lists_screen.dart';
import 'marking_review_screen.dart';

/// AI-Assisted Marking — "View Marked Scripts" (2026-08-31), reachable
/// from the capture screen (not just the queue hub) so a teacher can jump
/// to a script that needs a closer look without fully backing out of a
/// capture session first. Shows every [MarkingScriptStatus.graded] (AI
/// marked, awaiting review) and [MarkingScriptStatus.reviewed] (already
/// confirmed) script across every scheme — unlike MarkingQueueScreen's
/// own per-scheme "next in queue" chaining, this is a flat, complete
/// list, since the point here is finding one specific script, not
/// working through a batch in order.
///
/// Tapping a script offers three actions, matching what a teacher might
/// need to do with one they want to check closely: review it again
/// (open MarkingReviewScreen, editable either way), reprocess it (send
/// back to AI grading), or mark it as reviewed directly without
/// reopening the full review UI.
///
/// Manual results lists (added 2026-09-02): the AppBar's checkbox icon
/// toggles select mode — ticking scripts and choosing "Create New List"
/// moves them into a manually-curated, named list (see
/// marked_results_list.dart). A script that belongs to any list stops
/// appearing here, matching "gets moved to the new list" exactly; the
/// folder icon opens [MarkedResultsListsScreen] to see every list
/// created so far. Scores stay fully editable everywhere until a list
/// is exported/shared for the first time — see
/// MarkedResultsListDetailScreen._export and
/// MarkingReviewScreen.locked.
class MarkedScriptsScreen extends StatefulWidget {
  const MarkedScriptsScreen({super.key, this.repository, this.schemeRepository, this.listRepository});

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;
  final MarkedResultsListRepository? listRepository;

  @override
  State<MarkedScriptsScreen> createState() => _MarkedScriptsScreenState();
}

class _MarkedScriptsScreenState extends State<MarkedScriptsScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final MarkedResultsListRepository _listRepository = widget.listRepository ?? MarkedResultsListRepository();

  bool _loading = true;
  List<MarkingScript> _scripts = [];
  MarkingSchemeCatalog _schemes = MarkingSchemeCatalog.empty();

  bool _selectMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode ? '${_selectedIds.length} selected' : 'Marked Scripts'),
        actions: [
          if (_selectMode)
            TextButton(
              onPressed: _selectedIds.isEmpty ? null : _createNewList,
              child: const Text('New List'),
            )
          else ...[
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
                      onTap: _selectMode ? () => _toggleSelected(script.id) : () => _openActions(script),
                    );
                  },
                ),
    );
  }
}

enum _ScriptAction { review, reprocess, markReviewed }
