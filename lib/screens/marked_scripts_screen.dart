import 'package:flutter/material.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
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
class MarkedScriptsScreen extends StatefulWidget {
  const MarkedScriptsScreen({super.key, this.repository, this.schemeRepository});

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;

  @override
  State<MarkedScriptsScreen> createState() => _MarkedScriptsScreenState();
}

class _MarkedScriptsScreenState extends State<MarkedScriptsScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();

  bool _loading = true;
  List<MarkingScript> _scripts = [];
  MarkingSchemeCatalog _schemes = MarkingSchemeCatalog.empty();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await _repository.loadCatalog();
    final schemes = await _schemeRepository.loadCatalog();
    final marked = catalog.scripts
        .where((s) => s.status == MarkingScriptStatus.graded || s.status == MarkingScriptStatus.reviewed)
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
      appBar: AppBar(title: const Text('Marked Scripts')),
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
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            reviewed ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest,
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
                      onTap: () => _openActions(script),
                    );
                  },
                ),
    );
  }
}

enum _ScriptAction { review, reprocess, markReviewed }
