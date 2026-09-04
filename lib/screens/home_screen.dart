import 'package:flutter/material.dart';

import '../models/record_of_work.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../widgets/function_button.dart';
import 'assignments_tests_menu_screen.dart';
import 'class_resume_picker_screen.dart';
import 'data_manager_menu_screen.dart';
import 'generate_lesson_plan_flow.dart';
import 'handwriting_to_word_screen.dart';
import 'marking_queue_screen.dart';
import 'minutes_maker_screen.dart';
import 'record_of_work_screen.dart';
import 'scheme_of_work_document_screen.dart';
import 'settings_screen.dart';
import 'subject_grade_topic_picker_screen.dart';
import 'teaching_notes_sheet.dart';
import 'teaching_resources_menu_screen.dart';
import 'term_topic_picker_screen.dart';
import 'topic_picker_flow.dart';
import 'topic_search_screen.dart';
import 'word_pdf_converter_screen.dart';

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
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Generate Lesson Plan'),
      ),
    );
    if (template == null || !context.mounted) return;
    await startGenerateLessonPlanFlow(context, template);
  }

  /// "Generate Scheme of Work": subject → grade/form → term (for the real
  /// calendar dates shown in the document header — see
  /// SchemeOfWorkDocumentScreen._realCalendarNote), then always asks which
  /// class this is for and where it reached (ClassResumePickerScreen —
  /// never skipped, never silently trusted from a stored cursor alone) so
  /// the generated content starts at exactly the right topic. Coverage,
  /// not the picked term's own original topic list, drives what's
  /// included: the scheme can legitimately spill into a later term's
  /// topics (a class that's ahead) or fall short of them (a class that's
  /// behind) — see generateSchemeOfWorkForTerm's own doc comment.
  Future<void> _openSchemeOfWork(BuildContext context) async {
    final selection = await Navigator.of(context).push<TermSelection>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Generate Scheme of Work', pickTerm: true),
      ),
    );
    if (selection == null || !context.mounted) return;

    // "Topics in the Scheme" (2026-09-04, per explicit request) sits
    // alongside the existing resume flow here, not instead of it — a
    // teacher picking a specific topic directly, rather than resuming
    // from a real class's tracked progress.
    final choice = await showDialog<_SchemeStart>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Generate scheme of work'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_SchemeStart.resume),
            child: const ListTile(
              leading: Icon(Icons.history),
              title: Text('Resume from class progress'),
              subtitle: Text('Continues from where a specific class last left off'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_SchemeStart.topicsInScheme),
            child: const ListTile(
              leading: Icon(Icons.list_alt_outlined),
              title: Text('Topics in the Scheme'),
              subtitle: Text('Pick any topic to start this scheme from'),
            ),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;

    if (choice == _SchemeStart.topicsInScheme) {
      final picked = await Navigator.of(context).push<SchemeOfWorkEntry>(
        MaterialPageRoute(builder: (_) => TermTopicPickerScreen(template: selection.template)),
      );
      if (picked == null || !context.mounted) return;
      final entries = generateSchemeOfWorkStartingAt(selection.template, picked);
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SchemeOfWorkDocumentScreen(
          template: selection.template,
          entries: entries,
          targetTerm: selection.term,
        ),
      ));
      return;
    }

    final resume = await Navigator.of(context).push<ClassResumeSelection>(
      MaterialPageRoute(builder: (_) => ClassResumePickerScreen(template: selection.template)),
    );
    if (resume == null || !context.mounted) return;

    final entries = generateSchemeOfWorkForTerm(
      selection.template,
      resume.topicId,
      lastConcludedSubTopicId: resume.subTopicId,
    );

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SchemeOfWorkDocumentScreen(
        template: selection.template,
        entries: entries,
        classLabel: resume.classLabel,
        targetTerm: selection.term,
      ),
    ));
  }

  Future<void> _openTeachingNotes(BuildContext context) async {
    // Search-first (2026-09-02, Method 2 layered on Method 1) — was a
    // direct SubjectGradeTopicPickerScreen(pickTopic: true) push, a flatter
    // path that never grouped by real week and hardcoded weekNumber: 1 on
    // every result; see that screen's own doc comment for the fix.
    final result = await Navigator.of(context).push<TopicPickResult>(
      MaterialPageRoute(builder: (_) => const TopicSearchScreen(title: 'Generate Teaching Notes & Slides')),
    );
    if (result == null || !context.mounted) return;

    final format = await _pickNotesFormat(context);
    if (format == null || !context.mounted) return;

    await showTeachingNotesSheet(
      context,
      entry: result.entry,
      template: result.template,
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
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Generate Record of Work'),
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
                FunctionButton(
                  icon: Icons.assignment_outlined,
                  label: 'Generate Lesson Plan',
                  subtitle: 'New lesson, or resume one that was paused',
                  onTap: () => _openLessonPlan(context),
                ),
                FunctionButton(
                  icon: Icons.event_note_outlined,
                  label: 'Generate Scheme of Work',
                  subtitle: 'Pick a subject, grade/form, and term',
                  onTap: () => _openSchemeOfWork(context),
                ),
                FunctionButton(
                  icon: Icons.auto_awesome_outlined,
                  label: 'Generate Teaching Notes & Slides',
                  subtitle: 'Bulletin, essay, or PowerPoint slides, for one topic',
                  onTap: () => _openTeachingNotes(context),
                ),
                FunctionButton(
                  icon: Icons.fact_check_outlined,
                  label: 'Generate Record of Work',
                  subtitle: 'Weekly or fortnightly, pulled from what you\'ve already generated',
                  onTap: () => _openRecordOfWork(context),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                  child: Text(
                    'PUBLIC ACCESS LIBRARIES',
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant, letterSpacing: 0.8),
                  ),
                ),
                // Combined (2026-09-02) — CDC Teaching Modules, CDC Syllabi,
                // and ECZ Past Papers used to be two separate home-screen
                // buttons (one of which already internally combined syllabi
                // + past papers into sectioned lists); now all three are
                // separate, equal buttons living one level down, behind a
                // single home-screen entry point, to reduce home-screen
                // clutter without hiding any of the three real functions.
                FunctionButton(
                  icon: Icons.menu_book_outlined,
                  label: 'Teaching Modules, Syllabi & Past Papers',
                  subtitle: 'CDC Teaching Modules, CDC Syllabi, and ECZ Past Papers',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TeachingResourcesMenuScreen()),
                  ),
                ),
                FunctionButton(
                  icon: Icons.document_scanner_outlined,
                  label: 'Chief Marker',
                  subtitle: 'Marking assistant — capture and queue student scripts for AI-assisted grading (early build)',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MarkingQueueScreen()),
                  ),
                ),
                FunctionButton(
                  icon: Icons.edit_document,
                  label: 'Handwriting to Word Document Conversion',
                  subtitle: 'Photograph or upload a handwritten page, get back an editable Word document',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HandwritingToWordScreen()),
                  ),
                ),
                // Data Manager (2026-09-03, renamed from "Grade Teacher" per
                // explicit request): a home-screen entry point for
                // administrative/record-keeping functions, starting with
                // Grade Teacher (Report Form Pipeline — class roster, Broad
                // Mark Sheet, report forms) but structured to hold more than
                // one such function over time, same "button leads to a sub-
                // menu" pattern as Teaching Resources/Assignments & Tests
                // below — see DataManagerMenuScreen. Its own section, not
                // folded into Public Access Libraries or Admin Tools, since
                // this is administrative record-keeping, not content
                // browsing or office utilities.
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                  child: Text(
                    'DATA MANAGER',
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant, letterSpacing: 0.8),
                  ),
                ),
                FunctionButton(
                  icon: Icons.folder_shared_outlined,
                  label: 'Data Manager',
                  subtitle: 'Grade Teacher — class roster, Broad Mark Sheet, and report forms',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DataManagerMenuScreen()),
                  ),
                ),
                // Admin Tools — deliberately separate from the
                // curriculum/lesson features above: general-purpose office
                // utilities rather than anything syllabus-driven.
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                  child: Text(
                    'ADMIN TOOLS',
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant, letterSpacing: 0.8),
                  ),
                ),
                // Combined (2026-09-02) — Assignment Submission and Test
                // Submission used to be two side-by-side home-screen
                // buttons; now both live one level down, behind a single
                // home-screen entry point, same declutter rationale as the
                // Teaching Modules/Syllabi/Past Papers combination above.
                // Both keep their exact prior functions — nothing about
                // either feature changed here, only where they're reached
                // from. Moved to the top of Admin Tools (2026-09-02, per
                // explicit request) — swapped with Word ↔ PDF Converter,
                // which moved to the very bottom of the home screen.
                FunctionButton(
                  icon: Icons.assignment_turned_in_outlined,
                  label: 'Assignments, Exams & Test Submissions',
                  subtitle: 'Send a handwritten assignment or test to your teacher',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AssignmentsTestsMenuScreen()),
                  ),
                ),
                FunctionButton(
                  icon: Icons.groups_outlined,
                  label: 'Minutes Maker',
                  subtitle: 'Photograph handwritten meeting notes, get back formatted minutes',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MinutesMakerScreen()),
                  ),
                ),
                FunctionButton(
                  icon: Icons.picture_as_pdf_outlined,
                  label: 'Word ↔ PDF Converter',
                  subtitle: 'Convert a .docx file to PDF, entirely on-device',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const WordPdfConverterScreen()),
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

enum _SchemeStart { resume, topicsInScheme }
