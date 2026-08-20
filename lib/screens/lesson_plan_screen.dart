import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/lesson_checkpoint.dart';
import '../models/lesson_plan.dart';
import '../models/scheme_of_work.dart';
import '../services/custom_template_repository.dart';
import '../services/lesson_checkpoint_repository.dart';
import '../services/lesson_plan_document_service.dart';

/// Lets a teacher fill in a lesson plan template for one scheme-of-work
/// entry (topic/sub-topic already known from the syllabus), then export it
/// as PDF or Word and share it — entirely on-device, no network required.
///
/// Defaults to the bundled CDC template, but also offers any templates the
/// teacher uploaded themselves (Stage 3: "Upload My Own Template",
/// see [CustomTemplateRepository]) — switching templates rebuilds the form
/// around the newly selected field definitions.
///
/// Stage 6: "Resume Lesson" — the teacher can mark which Lesson Progression
/// stage they reached and save a checkpoint; opening the same lesson again
/// (identified by curriculum + subject + grade + topic + sub-topic) offers
/// to continue from there instead of starting over.
class LessonPlanScreen extends StatefulWidget {
  const LessonPlanScreen({
    super.key,
    required this.subjectName,
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.entry,
    this.template = defaultCdcLessonPlanTemplate,
    this.documentService,
    this.customTemplateRepository,
    this.checkpointRepository,
    this.guidedActivitiesText,
    this.guidedNoteText,
  });

  final String subjectName;
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final SchemeOfWorkEntry entry;
  final LessonPlanTemplate template;
  final LessonPlanDocumentService? documentService;
  final CustomTemplateRepository? customTemplateRepository;
  final LessonCheckpointRepository? checkpointRepository;

  /// Pre-fills the "Lesson Development" progression stage's Learners' Role
  /// (or the first stage, if none is named "Development") — set when
  /// arriving from Stage 5's guided planning with a chosen set of
  /// activities. Ignored for templates with no progression stages (e.g. a
  /// custom uploaded one), and superseded if the teacher chooses to resume
  /// a saved checkpoint instead.
  final String? guidedActivitiesText;

  /// Paired with [guidedActivitiesText]: suggested group size and any rule
  /// notices from guided planning, pre-filled into the same stage's
  /// Teacher's Role.
  final String? guidedNoteText;

  @override
  State<LessonPlanScreen> createState() => _LessonPlanScreenState();
}

class _LessonPlanScreenState extends State<LessonPlanScreen> {
  late final LessonPlanDocumentService _documentService = widget.documentService ?? LessonPlanDocumentService();
  late final CustomTemplateRepository _customTemplateRepository =
      widget.customTemplateRepository ?? CustomTemplateRepository();
  late final LessonCheckpointRepository _checkpointRepository =
      widget.checkpointRepository ?? LessonCheckpointRepository();

  List<LessonPlanTemplate> _availableTemplates = const [];
  late LessonPlanTemplate _activeTemplate;
  late LessonPlanDraft _draft;
  final Map<String, TextEditingController> _controllers = {};
  bool _exporting = false;
  int? _reachedStageIndex;

  @override
  void initState() {
    super.initState();
    _activeTemplate = widget.template;
    _availableTemplates = [widget.template];
    _rebuildForActiveTemplate();
    _loadCustomTemplates();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForCheckpoint());
  }

  Future<void> _loadCustomTemplates() async {
    final custom = await _customTemplateRepository.list();
    if (!mounted || custom.isEmpty) return;
    setState(() => _availableTemplates = [widget.template, ...custom]);
  }

  Future<void> _checkForCheckpoint() async {
    final checkpoint = await _checkpointRepository.find(
      curriculumCode: widget.curriculumCode,
      subjectCode: widget.subjectCode,
      gradeLevel: widget.gradeLevel,
      topicId: widget.entry.topic.id,
      subTopicId: widget.entry.subTopic?.id,
    );
    if (!mounted || checkpoint == null) return;

    final stages = checkpoint.draft.progression;
    final reachedStageName =
        checkpoint.reachedStageIndex >= 0 && checkpoint.reachedStageIndex < stages.length
            ? stages[checkpoint.reachedStageIndex].stage
            : 'a later stage';

    final resume = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Resume this lesson?'),
        content: Text(
          'You reached "$reachedStageName" last time (${_relativeTime(checkpoint.savedAt)}). '
          'Continue from there, or start fresh?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Start fresh')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Resume')),
        ],
      ),
    );
    if (resume != true || !mounted) return;

    final matchingTemplate = _availableTemplates.where((t) => t.id == checkpoint.templateId);
    setState(() {
      if (matchingTemplate.isNotEmpty) _activeTemplate = matchingTemplate.first;
      _rebuildForActiveTemplate(seedDraft: checkpoint.draft);
      _reachedStageIndex = checkpoint.reachedStageIndex;
    });
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Rebuilds `_draft` and every controller around `_activeTemplate`. Pass
  /// [seedDraft] to restore an exact prior draft (resuming a checkpoint);
  /// omitted, a fresh draft is built with the syllabus auto-fill values and
  /// any guided-planning prefill applied.
  void _rebuildForActiveTemplate({LessonPlanDraft? seedDraft}) {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();

    var draft = seedDraft;
    if (draft == null) {
      draft = LessonPlanDraft.empty(_activeTemplate)
          .withValue('subject', widget.subjectName)
          .withValue('topic', widget.entry.topic.name);
      if (widget.entry.subTopic != null) {
        draft = draft.withValue('subTopic', widget.entry.subTopic!.name);
      }
      final generalCompetences = widget.entry.topic.competencies.map((c) => c.description).join('\n');
      if (generalCompetences.isNotEmpty) {
        draft = draft.withValue('generalCompetences', generalCompetences);
      }
      final specificCompetences = widget.entry.competencies.map((c) => c.description).join('\n');
      if (specificCompetences.isNotEmpty) {
        draft = draft.withValue('specificCompetences', specificCompetences);
      }
      if (widget.entry.objectives.isNotEmpty) {
        draft = draft.withValue('expectedStandard', widget.entry.objectives.first.description);
      }
      if (widget.guidedActivitiesText != null && draft.progression.isNotEmpty) {
        final idx = draft.progression.indexWhere((r) => r.stage.toLowerCase().contains('development'));
        final targetIndex = idx == -1 ? 0 : idx;
        draft = draft.withProgressionRow(
          targetIndex,
          draft.progression[targetIndex].copyWith(
            learnersRole: widget.guidedActivitiesText,
            teacherRole: widget.guidedNoteText,
          ),
        );
      }
    }
    _draft = draft;

    for (final field in _activeTemplate.allFields) {
      _controllers[field.id] = TextEditingController(text: _draft.value(field.id));
    }
    for (var i = 0; i < _draft.progression.length; i++) {
      final row = _draft.progression[i];
      _controllers['progression_${i}_duration'] = TextEditingController(text: row.durationMinutes);
      _controllers['progression_${i}_teacher'] = TextEditingController(text: row.teacherRole);
      _controllers['progression_${i}_learners'] = TextEditingController(text: row.learnersRole);
      _controllers['progression_${i}_assessment'] = TextEditingController(text: row.assessmentCriteria);
    }
  }

  void _onTemplateChanged(LessonPlanTemplate? template) {
    if (template == null || template.id == _activeTemplate.id) return;
    setState(() {
      _activeTemplate = template;
      _reachedStageIndex = null;
      _rebuildForActiveTemplate();
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _syncDraftFromControllers() {
    for (final field in _activeTemplate.allFields) {
      _draft = _draft.withValue(field.id, _controllers[field.id]!.text);
    }
    for (var i = 0; i < _draft.progression.length; i++) {
      _draft = _draft.withProgressionRow(
        i,
        _draft.progression[i].copyWith(
          durationMinutes: _controllers['progression_${i}_duration']!.text,
          teacherRole: _controllers['progression_${i}_teacher']!.text,
          learnersRole: _controllers['progression_${i}_learners']!.text,
          assessmentCriteria: _controllers['progression_${i}_assessment']!.text,
        ),
      );
    }
  }

  Future<void> _saveCheckpoint() async {
    if (_reachedStageIndex == null) return;
    _syncDraftFromControllers();
    await _checkpointRepository.save(LessonCheckpoint(
      curriculumCode: widget.curriculumCode,
      subjectCode: widget.subjectCode,
      gradeLevel: widget.gradeLevel,
      topicId: widget.entry.topic.id,
      subTopicId: widget.entry.subTopic?.id,
      templateId: _activeTemplate.id,
      reachedStageIndex: _reachedStageIndex!,
      draft: _draft,
      savedAt: DateTime.now(),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Progress saved — reached "${_draft.progression[_reachedStageIndex!].stage}".')),
    );
  }

  Future<void> _export(bool asPdf) async {
    _syncDraftFromControllers();
    setState(() => _exporting = true);
    try {
      final file = asPdf
          ? await _documentService.generatePdf(_activeTemplate, _draft)
          : await _documentService.generateDocx(_activeTemplate, _draft);
      if (!mounted) return;
      // The OS share sheet is what actually surfaces WhatsApp, email,
      // Bluetooth, and every other installed share target — one call here
      // covers all of them rather than integrating each one separately.
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Lesson Plan — ${widget.entry.topic.name}',
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the document: $error')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Lesson Plan — ${widget.entry.title}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          if (_availableTemplates.length > 1) ...[
            DropdownButtonFormField<LessonPlanTemplate>(
              decoration: const InputDecoration(labelText: 'Template', border: OutlineInputBorder()),
              value: _activeTemplate,
              items: [
                for (final t in _availableTemplates) DropdownMenuItem(value: t, child: Text(t.name)),
              ],
              onChanged: _onTemplateChanged,
            ),
            const SizedBox(height: 12),
          ],
          Text(
            'Based on: ${_activeTemplate.source}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 16),
          for (final section in _activeTemplate.sections) ...[
            Text(section.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final field in section.fields) _buildField(field),
            const SizedBox(height: 16),
          ],
          if (_draft.progression.isNotEmpty) ...[
            Text('Lesson Progression', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Fixed stage order from the template — filled in per stage below.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _draft.progression.length; i++) _buildProgressionCard(i),
            const SizedBox(height: 8),
            Text('Resume Lesson', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              "Didn't finish teaching this? Mark the stage you reached and save — opening this lesson "
              'again will offer to continue from there.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _draft.progression.length; i++)
                  ChoiceChip(
                    label: Text(_draft.progression[i].stage),
                    selected: _reachedStageIndex == i,
                    onSelected: (_) => setState(() => _reachedStageIndex = i),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _reachedStageIndex == null ? null : _saveCheckpoint,
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('Save progress here'),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : () => _export(false),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Export Word'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _exporting ? null : () => _export(true),
                  icon: _exporting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Export PDF'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(LessonPlanFieldDef field) {
    if (field.autoFilled) {
      final value = _controllers[field.id]!.text;
      if (value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: RichText(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style,
            children: [
              TextSpan(text: '${field.label}: ', style: const TextStyle(fontWeight: FontWeight.bold)),
              TextSpan(text: value),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: _controllers[field.id],
        maxLines: field.type == LessonPlanFieldType.multiline ? 4 : 1,
        decoration: InputDecoration(
          labelText: field.required ? '${field.label} *' : field.label,
          helperText: field.helpText,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildProgressionCard(int index) {
    final stage = _draft.progression[index].stage;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(stage, style: Theme.of(context).textTheme.titleSmall),
                ),
                SizedBox(
                  width: 110,
                  child: TextFormField(
                    controller: _controllers['progression_${index}_duration'],
                    decoration: const InputDecoration(labelText: 'Duration', isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controllers['progression_${index}_teacher'],
              maxLines: 3,
              decoration: const InputDecoration(labelText: "Teacher's Role", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controllers['progression_${index}_learners'],
              maxLines: 3,
              decoration: const InputDecoration(labelText: "Learners' Role", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controllers['progression_${index}_assessment'],
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Assessment Criteria', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
    );
  }
}
