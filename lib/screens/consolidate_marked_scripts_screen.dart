import 'package:flutter/material.dart';

import '../models/marking_script.dart';
import '../models/report_class.dart';
import '../services/marking_script_repository.dart';
import '../services/report_class_repository.dart';
import 'class_setup_screen.dart';
import 'upload_score_sheet_flow.dart';

/// "Consolidate" — the answer to a real reported gap (2026-09-04): a class
/// marked across several separate Chief Marker sessions (today's 20
/// scripts, tomorrow's remaining 15) had no way to come back together as
/// one class, and no bridge existed at all from AI-Assisted Marking's
/// graded scripts into the Report Form Pipeline's Broad Mark Sheet — a
/// teacher would have had to retype every score by hand.
///
/// Two things, both requested: (1) every graded/reviewed script,
/// regardless of which session produced it, is grouped here by
/// (subject, grade, class/stream) automatically — no manual selection
/// needed, unlike MarkedScriptsScreen's existing "New List" feature; (2)
/// each group's "Consolidate into Broad Mark Sheet" button pushes those
/// scores into a real [ReportClass]'s Broad Mark Sheet, reusing
/// [UploadScoreSheetFlow]'s existing roster-matching/review/save pipeline
/// end to end (see its `initialExtractedRows`) rather than a parallel
/// implementation — every safeguard that pipeline already has (name
/// matching, "who is this?" resolution, nothing written until Confirm &
/// Save) applies here unchanged.
class ConsolidateMarkedScriptsScreen extends StatefulWidget {
  const ConsolidateMarkedScriptsScreen({super.key, this.scriptRepository, this.classRepository});

  final MarkingScriptRepository? scriptRepository;
  final ReportClassRepository? classRepository;

  @override
  State<ConsolidateMarkedScriptsScreen> createState() => _ConsolidateMarkedScriptsScreenState();
}

class _ScriptGroup {
  final String subjectName;
  final String gradeName;
  final String classLevel;
  final List<MarkingScript> scripts;

  _ScriptGroup({required this.subjectName, required this.gradeName, required this.classLevel, required this.scripts});

  String get key => '$subjectName|$gradeName|$classLevel';

  String get label => classLevel.isEmpty ? '$subjectName · $gradeName' : '$subjectName · $gradeName · $classLevel';

  /// Scripts with a real percentage — see MarkingScript.totalAwarded/
  /// totalPossible. A script still mid-grading (no maxMarks recorded yet)
  /// can't contribute a score and is excluded, with the count surfaced so
  /// nothing silently vanishes.
  List<MarkingScript> get scoredScripts => [for (final s in scripts) if (_percentFor(s) != null) s];
}

/// Distinguishable from any real [ReportClass] instance — returned by the
/// class-picker sheet's "New Class" tile so [_ConsolidateMarkedScriptsScreenState._pickReportClass]
/// can tell "chose to create one" apart from "picked an existing one" and
/// "dismissed the sheet" (null).
const _newClassChoice = Object();

double? _percentFor(MarkingScript script) {
  final awarded = script.totalAwarded;
  final possible = script.totalPossible;
  if (awarded == null || possible == null || possible == 0) return null;
  return (awarded / possible) * 100;
}

class _ConsolidateMarkedScriptsScreenState extends State<ConsolidateMarkedScriptsScreen> {
  late final MarkingScriptRepository _scriptRepository = widget.scriptRepository ?? MarkingScriptRepository();
  late final ReportClassRepository _classRepository = widget.classRepository ?? ReportClassRepository();

  bool _loading = true;
  List<_ScriptGroup> _groups = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await _scriptRepository.loadCatalog();
    final marked = catalog.scripts
        .where((s) => s.status == MarkingScriptStatus.graded || s.status == MarkingScriptStatus.reviewed)
        .toList();

    final byKey = <String, _ScriptGroup>{};
    for (final script in marked) {
      final group = byKey.putIfAbsent(
        '${script.subjectName}|${script.gradeName}|${script.classLevel}',
        () => _ScriptGroup(
          subjectName: script.subjectName,
          gradeName: script.gradeName,
          classLevel: script.classLevel,
          scripts: [],
        ),
      );
      group.scripts.add(script);
    }
    final groups = byKey.values.toList()..sort((a, b) => a.label.compareTo(b.label));
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
    });
  }

  Future<void> _consolidate(_ScriptGroup group) async {
    final scored = group.scoredScripts;
    if (scored.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('None of these scripts have a mark yet — nothing to consolidate.')),
      );
      return;
    }

    final reportClass = await _pickReportClass();
    if (reportClass == null || !mounted) return;

    final rows = [
      for (final script in scored) (name: script.fullName, score: _percentFor(script)!.toStringAsFixed(1)),
    ];

    final skipped = group.scripts.length - scored.length;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UploadScoreSheetFlow(
          reportClass: reportClass,
          repository: _classRepository,
          initialSubjectName: group.subjectName,
          initialExtractedRows: rows,
        ),
      ),
    );
    if (!mounted) return;
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$skipped script(s) in this group had no mark yet and were left out.')),
      );
    }
  }

  /// Existing classes first (most likely — a class's roster is usually set
  /// up before its scripts are marked), "+ New Class" always last. Doesn't
  /// try to auto-match by name — a group's [_ScriptGroup.gradeName]/
  /// classLevel are free text captured mid-marking, not guaranteed to
  /// match a [ReportClass.classGrade] string exactly, and guessing wrong
  /// here would silently push scores onto the wrong class's Broad Mark
  /// Sheet — the one thing this whole flow exists to get right.
  Future<ReportClass?> _pickReportClass() async {
    final classes = await _classRepository.listClasses();
    if (!mounted) return null;
    // The sheet returns either a picked ReportClass or this sentinel for
    // "New Class" — resolved AFTER the sheet has closed (below), rather
    // than pushing ClassSetupScreen from inside the sheet's own builder
    // context, which would pop the wrong screen off the stack once it
    // returned.
    final choice = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Consolidate into which class?', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in classes)
                    ListTile(
                      leading: const Icon(Icons.groups_outlined),
                      title: Text(c.classGrade),
                      subtitle: Text('${c.schoolName} · ${c.term}'),
                      onTap: () => Navigator.of(sheetContext).pop(c),
                    ),
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('New Class'),
                    onTap: () => Navigator.of(sheetContext).pop(_newClassChoice),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return null;
    if (choice is ReportClass) return choice;
    if (!mounted) return null;
    return Navigator.of(context).push<ReportClass>(
      MaterialPageRoute(builder: (_) => ClassSetupScreen(repository: _classRepository)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Consolidate Classes')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _groups.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.merge_type, size: 48, color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        const Text(
                          'No marked scripts yet. Once scripts are graded, they\'ll be grouped here by subject, '
                          'grade and class — ready to push into that class\'s Broad Mark Sheet.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _groups.length,
                  itemBuilder: (context, index) {
                    final group = _groups[index];
                    final scoredCount = group.scoredScripts.length;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.groups_outlined),
                        title: Text(group.label),
                        subtitle: Text(
                          scoredCount == group.scripts.length
                              ? '${group.scripts.length} script(s), all marked'
                              : '${group.scripts.length} script(s) — $scoredCount marked, '
                                  '${group.scripts.length - scoredCount} still awaiting a mark',
                        ),
                        trailing: FilledButton(
                          onPressed: () => _consolidate(group),
                          child: const Text('Consolidate'),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
