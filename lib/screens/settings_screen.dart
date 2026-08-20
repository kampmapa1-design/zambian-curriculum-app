import 'package:flutter/material.dart';

import '../models/lesson_plan.dart';
import '../services/custom_template_repository.dart';
import 'template_upload_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.repository});

  final CustomTemplateRepository? repository;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final CustomTemplateRepository _repository = widget.repository ?? CustomTemplateRepository();
  List<LessonPlanTemplate> _customTemplates = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final templates = await _repository.list();
    if (!mounted) return;
    setState(() {
      _customTemplates = templates;
      _loading = false;
    });
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
              ],
            ),
    );
  }
}
