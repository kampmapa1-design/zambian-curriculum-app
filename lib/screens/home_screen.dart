import 'package:flutter/material.dart';

import '../models/record_of_work.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import 'cdc_resources_screen.dart';
import 'generate_lesson_plan_flow.dart';
import 'handwriting_to_word_screen.dart';
import 'marking_queue_screen.dart';
import 'record_of_work_screen.dart';
import 'scheme_of_work_document_screen.dart';
import 'settings_screen.dart';
import 'subject_grade_topic_picker_screen.dart';
import 'teaching_notes_sheet.dart';

/// The app's home screen: a branded header (not a bare list dropped
/// straight under the system status bar) followed by one clearly labeled
/// button per major function, rather than features only reachable by first
/// drilling into a browsed syllabus. Each "Generate ..." button picks
/// curriculum/subject/grade (and, where relevant, topic) first, then does
/// its one job.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _openLessonPlan(BuildContext context) async {
    final template = await Navigator.of(context).push<SyllabusTemplate>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Generate Lesson Plan', pickTopic: false),
      ),
    );
    if (template == null || !context.mounted) return;
    await startGenerateLessonPlanFlow(context, template);
  }

  /// "Generate Scheme of Work" does exactly one thing: subject → grade/form
  /// → term, then straight to the generated document for that term. No
  /// lesson-plan, teaching-notes, or slide shortcuts live under this button
  /// — those are their own separate "Generate ..." entry points.
  Future<void> _openSchemeOfWork(BuildContext context) async {
    final selection = await Navigator.of(context).push<TermSelection>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Generate Scheme of Work', pickTopic: false, pickTerm: true),
      ),
    );
    if (selection == null || !context.mounted) return;

    final allEntries = generateSchemeOfWork(selection.template, null);
    final topicIdsInTerm = selection.term.topics.map((t) => t.id).toSet();
    final termEntries = allEntries.where((e) => topicIdsInTerm.contains(e.topic.id)).toList();

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SchemeOfWorkDocumentScreen(template: selection.template, entries: termEntries),
    ));
  }

  Future<void> _openTeachingNotes(BuildContext context) async {
    final entry = await Navigator.of(context).push<SchemeOfWorkEntry>(
      MaterialPageRoute(
        builder: (_) =>
            const SubjectGradeTopicPickerScreen(title: 'Generate Teaching Notes & Slides', pickTopic: true),
      ),
    );
    if (entry == null || !context.mounted) return;

    final format = await _pickNotesFormat(context);
    if (format == null || !context.mounted) return;

    await showTeachingNotesSheet(
      context,
      entry: entry,
      initialFormat: format == 'paragraph' ? 'paragraph' : 'bullet',
      autoGenerateSlides: format == 'slide',
    );
  }

  Future<String?> _pickNotesFormat(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Prepare notes as…'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('bullet'),
            child: const ListTile(
              leading: Icon(Icons.format_list_bulleted),
              title: Text('Bulletin'),
              subtitle: Text('Concise bullet points'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('paragraph'),
            child: const ListTile(
              leading: Icon(Icons.article_outlined),
              title: Text('Essay'),
              subtitle: Text('Flowing prose, up to 700 words'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('slide'),
            child: const ListTile(
              leading: Icon(Icons.slideshow_outlined),
              title: Text('Slide'),
              subtitle: Text('PowerPoint deck, shared immediately'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openRecordOfWork(BuildContext context) async {
    final period = await showDialog<RecordOfWorkPeriod>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Generate Record of Work'),
        children: [
          for (final p in RecordOfWorkPeriod.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(p),
              child: Text(p.label),
            ),
        ],
      ),
    );
    if (period == null || !context.mounted) return;

    final template = await Navigator.of(context).push<SyllabusTemplate>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Generate Record of Work', pickTopic: false),
      ),
    );
    if (template == null || !context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RecordOfWorkScreen(template: template, period: period)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 200,
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [colorScheme.primary, colorScheme.primaryContainer],
                  ),
                ),
                child: SafeArea(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Image.asset('assets/icon/icon.png', width: 72, height: 72),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Smart Teacher',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: colorScheme.onPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Zambian Curriculum Companion',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onPrimary.withValues(alpha: 0.85),
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: [
                _FunctionButton(
                  icon: Icons.assignment_outlined,
                  label: 'Generate Lesson Plan',
                  subtitle: 'New lesson, or resume one that was paused',
                  onTap: () => _openLessonPlan(context),
                ),
                _FunctionButton(
                  icon: Icons.event_note_outlined,
                  label: 'Generate Scheme of Work',
                  subtitle: 'Pick a subject, grade/form, and term',
                  onTap: () => _openSchemeOfWork(context),
                ),
                _FunctionButton(
                  icon: Icons.auto_awesome_outlined,
                  label: 'Generate Teaching Notes & Slides',
                  subtitle: 'Bulletin, essay, or PowerPoint slides, for one topic',
                  onTap: () => _openTeachingNotes(context),
                ),
                _FunctionButton(
                  icon: Icons.fact_check_outlined,
                  label: 'Generate Record of Work',
                  subtitle: 'Weekly or fortnightly, pulled from what you\'ve already generated',
                  onTap: () => _openRecordOfWork(context),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                  child: Text(
                    'CDC DIGITAL LIBRARY',
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant, letterSpacing: 0.8),
                  ),
                ),
                _FunctionButton(
                  icon: Icons.collections_bookmark_outlined,
                  label: 'CDC Teaching Modules',
                  subtitle: 'Browse and download official Teaching Modules',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          const CdcResourcesScreen(resourceType: 'module', title: 'CDC Teaching Modules'),
                    ),
                  ),
                ),
                _FunctionButton(
                  icon: Icons.description_outlined,
                  label: 'ECZ Past Papers & CDC Syllabi',
                  subtitle: 'Official syllabus documents, plus past exam papers',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CdcResourcesScreen(
                        title: 'ECZ Past Papers & CDC Syllabi',
                        sections: [
                          CdcResourceSection(resourceType: 'syllabus', heading: null),
                          CdcResourceSection(resourceType: 'past_paper', heading: 'ECZ Past Papers'),
                        ],
                      ),
                    ),
                  ),
                ),
                _FunctionButton(
                  icon: Icons.document_scanner_outlined,
                  label: 'AI-Assisted Marking',
                  subtitle: 'Capture and queue student scripts for AI-assisted grading (early build)',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MarkingQueueScreen()),
                  ),
                ),
                _FunctionButton(
                  icon: Icons.edit_document,
                  label: 'Handwriting to Word Document Conversion',
                  subtitle: 'Photograph or upload a handwritten page, get back an editable Word document',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HandwritingToWordScreen()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FunctionButton extends StatelessWidget {
  const _FunctionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            leading: CircleAvatar(
              radius: 22,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(icon, color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
      ),
    );
  }
}
