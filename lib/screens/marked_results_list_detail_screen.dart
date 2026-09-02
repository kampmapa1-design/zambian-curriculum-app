import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/marked_results_list.dart';
import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/marked_results_list_repository.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import '../services/marksheet_document_service.dart';
import 'marking_review_screen.dart';

/// One manually-curated results list's member scripts (added 2026-09-02),
/// with the "Export & Share" action that flips [MarkedResultsList.exported]
/// permanently true — the literal "remain editable until exported or
/// shared" gate: every score here stays editable right up until that tap,
/// then every script opens read-only from here on (see
/// [MarkingReviewScreen.locked]).
class MarkedResultsListDetailScreen extends StatefulWidget {
  const MarkedResultsListDetailScreen({
    super.key,
    required this.list,
    this.listRepository,
    this.scriptRepository,
    this.schemeRepository,
    this.documentService,
  });

  final MarkedResultsList list;
  final MarkedResultsListRepository? listRepository;
  final MarkingScriptRepository? scriptRepository;
  final MarkingSchemeRepository? schemeRepository;
  final MarksheetDocumentService? documentService;

  @override
  State<MarkedResultsListDetailScreen> createState() => _MarkedResultsListDetailScreenState();
}

class _MarkedResultsListDetailScreenState extends State<MarkedResultsListDetailScreen> {
  late final MarkedResultsListRepository _listRepository = widget.listRepository ?? MarkedResultsListRepository();
  late final MarkingScriptRepository _scriptRepository = widget.scriptRepository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final MarksheetDocumentService _documentService = widget.documentService ?? MarksheetDocumentService();

  late MarkedResultsList _list = widget.list;
  bool _loading = true;
  bool _exporting = false;
  List<MarkingScript> _scripts = [];
  MarkingSchemeCatalog _schemes = MarkingSchemeCatalog.empty();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await _scriptRepository.loadCatalog();
    final schemes = await _schemeRepository.loadCatalog();
    final byId = {for (final s in catalog.scripts) s.id: s};
    final scripts = [for (final id in _list.scriptIds) if (byId[id] case final s?) s]
      ..sort((a, b) {
        final bySurname = a.surname.toLowerCase().compareTo(b.surname.toLowerCase());
        return bySurname != 0 ? bySurname : a.firstName.toLowerCase().compareTo(b.firstName.toLowerCase());
      });
    if (!mounted) return;
    setState(() {
      _scripts = scripts;
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

  /// Groups by scheme (a manually-curated list can span more than one —
  /// MarksheetDocumentService needs one scheme per document, since its
  /// columns are that scheme's own questions), generates one marksheet
  /// per scheme present, and shares them all together in one share-sheet
  /// call. Flips [MarkedResultsList.exported] permanently true on
  /// success — the gate every script's score-editing checks from then on.
  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final byScheme = <String, List<MarkingScript>>{};
      final noScheme = <MarkingScript>[];
      for (final script in _scripts) {
        if (script.schemeId == null) {
          noScheme.add(script);
        } else {
          byScheme.putIfAbsent(script.schemeId!, () => []).add(script);
        }
      }

      final files = <XFile>[];
      for (final entry in byScheme.entries) {
        final scheme = _schemes.schemes.where((s) => s.id == entry.key).firstOrNull;
        if (scheme == null) continue;
        final file = await _documentService.generateDocx(scheme, entry.value);
        files.add(XFile(file.path));
      }

      if (files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Nothing to export — these scripts aren't linked to a marking scheme.")),
          );
        }
        return;
      }

      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: files, subject: '${_list.name} — Results'));

      final updated = _list.copyWith(exported: true, exportedAt: DateTime.now());
      await _listRepository.update(updated);
      if (!mounted) return;
      setState(() => _list = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shared — scores in this list are now locked.')),
      );
      if (noScheme.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${noScheme.length} script(s) had no linked scheme and were left out of the document.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export: $error')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openScript(MarkingScript script) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MarkingReviewScreen(
          script: script,
          scheme: _schemeFor(script),
          repository: _scriptRepository,
          locked: _list.exported,
        ),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_list.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_list.exported)
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.errorContainer,
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline, size: 18, color: Theme.of(context).colorScheme.onErrorContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Exported/shared — every score in this list is locked.',
                            style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _scripts.length,
                    itemBuilder: (context, index) {
                      final script = _scripts[index];
                      final scheme = _schemeFor(script);
                      final percent = _percentFor(script);
                      return ListTile(
                        title: Text(script.fullName),
                        subtitle: Text('${scheme?.title ?? script.subjectName} · ${script.gradeName}'),
                        trailing: percent == null ? null : Text('${percent.toStringAsFixed(1)}%', style: const TextStyle(fontWeight: FontWeight.bold)),
                        onTap: () => _openScript(script),
                      );
                    },
                  ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.share_outlined),
            label: Text(_exporting
                ? 'Exporting…'
                : (_list.exported ? 'Export & Share Again' : 'Export & Share')),
          ),
        ),
      ),
    );
  }
}
