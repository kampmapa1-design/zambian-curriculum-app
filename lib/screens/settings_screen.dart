import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/lesson_plan.dart';
import '../models/subject_content_item.dart';
import '../services/custom_template_repository.dart';
import '../services/subject_content_repository.dart';
import 'template_upload_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.repository, this.subjectContentRepository});

  final CustomTemplateRepository? repository;
  final SubjectContentRepository? subjectContentRepository;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final CustomTemplateRepository _repository = widget.repository ?? CustomTemplateRepository();
  late final SubjectContentRepository _subjectContentRepository =
      widget.subjectContentRepository ?? SubjectContentRepository();
  List<LessonPlanTemplate> _customTemplates = [];
  SubjectContentCatalog _subjectContent = SubjectContentCatalog.empty();
  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final templates = await _repository.list();
    final subjectContent = await _subjectContentRepository.loadCatalog();
    if (!mounted) return;
    setState(() {
      _customTemplates = templates;
      _subjectContent = subjectContent;
      _loading = false;
    });
    // Opportunistic — upgrades any item not yet holding AI-quality text
    // (still a raw PDF, or usable only via the on-device extraction
    // fallback) to the lean AI-extracted text format, silently, if the app
    // happens to be online right now.
    final converted = await _subjectContentRepository.migrateLegacyItems();
    if (converted > 0 && mounted) {
      final refreshed = await _subjectContentRepository.loadCatalog();
      if (mounted) setState(() => _subjectContent = refreshed);
    }
  }

  Future<void> _deleteSubjectContent(SubjectContentItem item) async {
    await _subjectContentRepository.remove(item);
    _load();
  }

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _delete(LessonPlanTemplate template) async {
    await _repository.delete(template.id);
    _load();
  }

  Future<void> _openUpload() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const TemplateUploadScreen()),
    );
    if (saved == true) _load();
  }

  /// Lets a teacher add their own PDF — a Teaching Module, syllabus, or
  /// any other "Subject Content Material" — straight into the on-device
  /// database, the same way a CDC download does: text is extracted and
  /// stored lean, ready for lesson plans, teaching notes, and slides to
  /// draw on, entirely offline from then on.
  Future<void> _importMaterial() async {
    final results = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (results.isEmpty || !mounted) return;
    final picked = results.single;

    final subjectName = await _askSubjectName();
    if (subjectName == null || !mounted) return;

    setState(() => _importing = true);
    try {
      final bytes = await picked.readAsBytes();
      final title = picked.name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      await _subjectContentRepository.store(
        title: title,
        subjectName: subjectName,
        resourceType: 'module',
        // A locally-imported file has no CDC catalog URL — this marker
        // plus the title keeps it unique enough not to collide with a
        // real download of the same material later.
        sourceUrl: 'local-import://$subjectName/$title',
        bytes: bytes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Added to your Subject Content Database.')),
      );
      _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add this file: $error')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<String?> _askSubjectName() async {
    final controller = TextEditingController(
      text: _subjectContent.items.isNotEmpty ? _subjectContent.bySubject.keys.first : '',
    );
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Which subject is this for?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Civic Education'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              Navigator.of(dialogContext).pop(value.isEmpty ? null : value);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Lesson plan templates', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                const Text(
                  'The bundled CDC template is always available. Upload your own to use it as an '
                  'alternative when generating a lesson plan.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('Upload My Own Template'),
                  subtitle: const Text('.docx — extract section headings and map them to app fields'),
                  onTap: _openUpload,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                ),
                if (_customTemplates.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Your uploaded templates', style: Theme.of(context).textTheme.labelLarge),
                  for (final template in _customTemplates)
                    Card(
                      margin: const EdgeInsets.only(top: 8),
                      child: ListTile(
                        title: Text(template.name),
                        subtitle: Text('${template.allFields.length} field(s)'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete',
                          onPressed: () => _delete(template),
                        ),
                      ),
                    ),
                ],
                const Divider(height: 32),
                Text('Subject Content Database', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '${_subjectContent.items.length} item(s), '
                  '${_formatSize(_subjectContent.totalSizeBytes)} total — kept on-device and used automatically '
                  'to enrich lesson plans, teaching notes, and slides, even offline. Some material comes '
                  'built into the app already; saving a CDC download to your database, or adding your own '
                  'below, adds more.',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: _importing
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add_circle_outline),
                  title: const Text('Add More Material (optional)'),
                  subtitle: const Text('Import a PDF — a Teaching Module or similar — from your device'),
                  onTap: _importing ? null : _importMaterial,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                ),
                for (final entry in _subjectContent.bySubject.entries) ...[
                  const SizedBox(height: 12),
                  Text(entry.key, style: Theme.of(context).textTheme.labelLarge),
                  for (final item in entry.value)
                    Card(
                      margin: const EdgeInsets.only(top: 6),
                      child: ListTile(
                        dense: true,
                        title: Text(item.title),
                        subtitle: Text(
                          '${item.resourceType} · ${_formatSize(item.sizeBytes)}'
                          '${item.isLegacyPdf ? ' · will convert next time you\'re online' : ''}'
                          '${item.extractedOnDevice ? ' · extracted offline, will refine next time you\'re online' : ''}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Remove',
                          onPressed: () => _deleteSubjectContent(item),
                        ),
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}
