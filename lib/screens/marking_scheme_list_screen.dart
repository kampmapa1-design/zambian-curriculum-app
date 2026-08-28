import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/marking_key_generation_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import '../services/marksheet_document_service.dart';
import 'marking_analysis_screen.dart';
import 'marking_key_upload_flow.dart';
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
  bool _generatingKey = false;

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
    final choice = await showDialog<_NewSchemeChoice>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('New Marking Scheme'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_NewSchemeChoice.manual),
            child: const Row(
              children: [
                Icon(Icons.edit_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Enter manually')),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_NewSchemeChoice.fromQuestionPaper),
            child: const Row(
              children: [
                Icon(Icons.auto_awesome_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Generate from a question paper (AI)')),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_NewSchemeChoice.fromExistingKey),
            child: const Row(
              children: [
                Icon(Icons.fact_check_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Read from an existing marking key (AI)')),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

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

    if (choice == _NewSchemeChoice.manual) {
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
      return;
    }

    final sourceType = choice == _NewSchemeChoice.fromExistingKey
        ? MarkingKeySourceType.markingKey
        : MarkingKeySourceType.questionPaper;

    final method = await showDialog<MarkingKeyUploadMethod>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('How will you provide it?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(MarkingKeyUploadMethod.uploadFromDevice),
            child: const Row(
              children: [
                Icon(Icons.upload_file_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Upload from device (PDF or photo)')),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(MarkingKeyUploadMethod.camera),
            child: const Row(
              children: [
                Icon(Icons.camera_alt_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Capture with camera')),
              ],
            ),
          ),
        ],
      ),
    );
    if (method == null || !mounted) return;

    final saved = await runMarkingKeyUploadFlow(
      context: context,
      sourceType: sourceType,
      method: method,
      schemeRepository: _repository,
      onLoadingChanged: (loading) {
        if (mounted) setState(() => _generatingKey = loading);
      },
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

  Future<void> _openAnalysis(MarkingScheme scheme) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MarkingAnalysisScreen(scheme: scheme, scriptRepository: _scriptRepository)),
    );
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

  Future<void> _exportMarksheet(MarkingScheme scheme, {required _MarksheetFormat format}) async {
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
      final file = switch (format) {
        _MarksheetFormat.pdf => await _marksheetService.generatePdf(scheme, scripts),
        _MarksheetFormat.docx => await _marksheetService.generateDocx(scheme, scripts),
        _MarksheetFormat.csv => await _marksheetService.generateCsv(scheme, scripts),
      };
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
                                      case 'analysis':
                                        _openAnalysis(scheme);
                                      case 'pdf':
                                        _exportMarksheet(scheme, format: _MarksheetFormat.pdf);
                                      case 'docx':
                                        _exportMarksheet(scheme, format: _MarksheetFormat.docx);
                                      case 'csv':
                                        _exportMarksheet(scheme, format: _MarksheetFormat.csv);
                                      case 'delete':
                                        _delete(scheme);
                                    }
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                                    PopupMenuItem(value: 'analysis', child: Text('Analysis')),
                                    PopupMenuItem(value: 'pdf', child: Text('Export Marksheet (PDF)')),
                                    PopupMenuItem(value: 'docx', child: Text('Export Marksheet (Word)')),
                                    PopupMenuItem(value: 'csv', child: Text('Export Marksheet (Excel/CSV)')),
                                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                                  ],
                                ),
                        ),
                      ),
                  ],
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _generatingKey ? null : _createNew,
        icon: _generatingKey
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add),
        label: Text(_generatingKey ? 'Generating…' : 'New Scheme'),
      ),
    );
  }
}

enum _NewSchemeChoice { manual, fromQuestionPaper, fromExistingKey }

enum _MarksheetFormat { pdf, docx, csv }
