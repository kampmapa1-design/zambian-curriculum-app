import 'package:flutter/material.dart';

import '../models/syllabus_models.dart';
import 'cdc_resources_screen.dart';
import 'curriculum_grade_picker_screen.dart';
import 'generate_lesson_plan_flow.dart';
import 'scheme_of_work_screen.dart';
import 'settings_screen.dart';
import 'subject_selector_screen.dart';
import 'teaching_notes_sheet.dart';
import 'topic_picker_screen.dart';

/// The app's home screen: a branded header (not a bare list dropped
/// straight under the system status bar) followed by one clearly labeled
/// button per major function, rather than features only reachable by first
/// drilling into a browsed syllabus. Each "Generate ..." button picks
/// curriculum/subject/grade (and, where relevant, topic) first, then does
/// its one job.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<SyllabusTemplate?> _pickTemplate(BuildContext context, String title) {
    return Navigator.of(context).push<SyllabusTemplate>(
      MaterialPageRoute(builder: (_) => CurriculumGradePickerScreen(title: title)),
    );
  }

  Future<void> _openLessonPlan(BuildContext context) async {
    final template = await _pickTemplate(context, 'Generate Lesson Plan');
    if (template == null || !context.mounted) return;
    await startGenerateLessonPlanFlow(context, template);
  }

  Future<void> _openSchemeOfWork(BuildContext context) async {
    final template = await _pickTemplate(context, 'Generate Scheme of Work');
    if (template == null || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SchemeOfWorkScreen(template: template)));
  }

  Future<void> _openTeachingNotes(BuildContext context) async {
    final template = await _pickTemplate(context, 'Generate Teaching Notes');
    if (template == null || !context.mounted) return;
    final entry = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TopicPickerScreen(template: template)),
    );
    if (entry == null || !context.mounted) return;
    await showTeachingNotesSheet(context, entry: entry);
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
                  icon: Icons.menu_book_outlined,
                  label: 'Browse Syllabus',
                  subtitle: 'View the full syllabus for a subject and grade',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SubjectSelectorScreen()),
                  ),
                ),
                _FunctionButton(
                  icon: Icons.assignment_outlined,
                  label: 'Generate Lesson Plan',
                  subtitle: 'New lesson, or resume one that was paused',
                  onTap: () => _openLessonPlan(context),
                ),
                _FunctionButton(
                  icon: Icons.event_note_outlined,
                  label: 'Generate Scheme of Work',
                  subtitle: 'Auto-continue from the last topic concluded',
                  onTap: () => _openSchemeOfWork(context),
                ),
                _FunctionButton(
                  icon: Icons.auto_awesome_outlined,
                  label: 'Generate Teaching Notes',
                  subtitle: 'Bullet points or paragraph form, for one topic',
                  onTap: () => _openTeachingNotes(context),
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
                  label: 'CDC Syllabi',
                  subtitle: 'Browse and download official syllabus documents',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CdcResourcesScreen(resourceType: 'syllabus', title: 'CDC Syllabi'),
                    ),
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
