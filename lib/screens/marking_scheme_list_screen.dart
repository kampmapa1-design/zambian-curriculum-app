import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import '../services/marksheet_document_service.dart';
import 'marking_scheme_builder_screen.dart';
import 'subject_grade_topic_picker_screen.dart';
import 'term_topic_picker_screen.dart';

/// AI-Assisted Marking, Stage 3 hub — every saved marking scheme, and the
/// entry point to build a new one (always starting from a real
/// subject/grade/topic pick, never free text — see [_createNew]). Also
/// Stage 7's entry point: exporting a class marksheet aggregated from
/// every reviewed script linked to a scheme (see [_exportMarksheet]).
class MarkingSchemeListScreen extends StatefulWidget {
  const MarkingSchemeListScreen({super.key, this.repository, this.scriptRepository, this.marksheetService});

  final MarkingSchemeRepository? repository;
  final MarkingScriptRepository? scriptRepository;
  final MarksheetDocumentService? marksheetService;

  @override
  State<MarkingSchemeListScreen> createState() => _MarkingSchemeListScreenState();
}

class _MarkingSchemeListScreenState extends State<MarkingSchemeListScreen> {
  late final MarkingSchemeRepository _repository = widget.repository ?? MarkingSchemeRepository();
  late final MarkingScriptRepository _scriptRepository = widget.scriptRepository ?? MarkingScriptRepository();
  late final MarksheetDocumentService _marksheetService = widget.marksheetService ?? MarksheetDocumentService();

  MarkingSchemeCatalog _catalog = MarkingSchemeCatalog.empty();
  bool _loading = true;
  String? _exportingSchemeId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await _repository.loadCatalog();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _loading = false;
    });
  }

  Future<void> _createNew() async {
    final template = await Navigator.of(context).push<SyllabusTemplate>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'New Marking Scheme', pickTopic: false),
      ),
    );
    if (template == null || !mounted) return;

    final entry = await Navigator.of(context).push<SchemeOfWorkEntry>(
      MaterialPageRoute(builder: (_) => TermTopicPickerScreen(template: template)),
    );
    if (entry == null || !mounted) return;

    final saved = await Navigator.of(context).push<MarkingScheme>(
      MaterialPageRoute(
        builder: (_) => MarkingSchemeBuilderScreen(
          subjectName: template.subject.name,
          gradeName: template.grade.name,
          topicName: entry.topic.name,
          subTopicName: entry.subTopic?.name,
          repository: _repository,
        ),
      ),
    );
    if (saved != null) _load();
  }

  Future<void> _edit(MarkingScheme scheme) async {
    final saved = await Navigator.of(context).push<MarkingScheme>(
      MaterialPageRoute(
        builder: (_) => MarkingSchemeBuilderScreen(
          subjectName: scheme.subjectName,
          gradeName: scheme.gradeName,
          topicName: scheme.topicName,
          subTopicName: scheme.subTopicName,
          existing: scheme,
          repository: _repository,
        ),
      ),
    );
    if (saved != null) _load();
  }

  Future<void> _delete(MarkingScheme scheme) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this marking scheme?'),
        content: Text('"${scheme.title}" will be permanently deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.remove(scheme);
    _load();
  }

  Future<void> _exportMarksheet(MarkingScheme scheme, {required bool asCsv}) async {
    final allScripts = (await _scriptRepository.loadCatalog()).scripts;
    final scripts = allScripts.where((s) => s.schemeId == scheme.id).toList();
    final reviewedCount = scripts.where((s) => s.status == MarkingScriptStatus.reviewed).length;

    if (reviewedCount == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No scripts for this scheme have completed review yet.')),
      );
      return;
    }

    setState(() => _exportingSchemeId = scheme.id);
    try {
      final file = asCsv
          ? await _marksheetService.generateCsv(scheme, scripts)
          : await _marksheetService.generatePdf(scheme, scripts);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Marksheet — ${scheme.title}'));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create the marksheet: $error')));
    } finally {
      if (mounted) setState(() => _exportingSchemeId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Marking Schemes')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _catalog.schemes.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.fact_check_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        const Text(
                          'No marking schemes yet. Build one to define each question, expected answer, '
                          'and mark allocation for an assessment — reuse it across every script from '
                          'that same assessment.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    for (final scheme in _catalog.schemes)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text(scheme.title),
                          subtitle: Text(
                            '${scheme.subjectName} · ${scheme.gradeName} · '
                            '${scheme.questions.length} question(s) · ${scheme.totalMarks.toStringAsFixed(scheme.totalMarks == scheme.totalMarks.roundToDouble() ? 0 : 1)} marks',
                          ),
                          onTap: () => _edit(scheme),
                          trailing: _exportingSchemeId == scheme.id
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : PopupMenuButton<String>(
                                  onSelected: (choice) {
                                    switch (choice) {
                                      case 'edit':
                                        _edit(scheme);
                                      case 'pdf':
                                        _exportMarksheet(scheme, asCsv: false);
                                      case 'csv':
                                        _exportMarksheet(scheme, asCsv: true);
                                      case 'delete':
                                        _delete(scheme);
                                    }
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                                    PopupMenuItem(value: 'pdf', child: Text('Export Marksheet (PDF)')),
                                    PopupMenuItem(value: 'csv', child: Text('Export Marksheet (Excel/CSV)')),
                                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                                  ],
                                ),
                        ),
                      ),
                  ],
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNew,
        icon: const Icon(Icons.add),
        label: const Text('New Scheme'),
      ),
    );
  }
}
