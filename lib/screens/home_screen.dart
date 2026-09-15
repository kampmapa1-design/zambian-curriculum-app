import 'package:flutter/material.dart';

import '../models/record_of_work.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../widgets/cdc_new_materials_banner.dart';
import '../widgets/function_button.dart';
import 'assignments_tests_menu_screen.dart';
import 'class_resume_picker_screen.dart';
import 'data_manager_menu_screen.dart';
import 'generate_lesson_plan_flow.dart';
import 'handwriting_to_word_screen.dart';
import 'marking_queue_screen.dart';
import 'office_tools_menu_screen.dart';
import 'record_of_work_screen.dart';
import 'scheme_of_work_document_screen.dart';
import 'select_own_topics_screen.dart';
import 'select_own_topics_subject_picker_screen.dart';
import 'settings_screen.dart';
import 'subject_grade_topic_picker_screen.dart';
import 'teaching_notes_sheet.dart';
import 'teaching_resources_menu_screen.dart';
import 'term_topic_picker_screen.dart';
import 'timetable_home_screen.dart';
import 'topic_picker_flow.dart';
import 'topic_search_screen.dart';
import 'voice_command_screen.dart';

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
  /// SchemeOfWorkDocumentScreen._realCalendarNote), then "One off scheme of
  /// work?" (2026-09-06, replaces the older "Resume from class progress" /
  /// "Topics in the Scheme" wording with an explicit yes/no gate — same two
  /// underlying paths, clearer framing of what each one means):
  ///
  /// - **Yes** (one-off): no class name needed at all — pick any topic to
  ///   start this scheme from (via [TermTopicPickerScreen]'s own default,
  ///   fresh-class windows), and nothing about it is written to this app's
  ///   own records (SchemeOfWorkDocumentScreen skips both the lesson-history
  ///   log and any class progress update whenever `classLabel` is null —
  ///   see that field's own doc comment).
  /// - **No**: always asks which class this is for and where it reached
  ///   (ClassResumePickerScreen — never skipped, never silently trusted
  ///   from a stored cursor alone) so the generated content starts at
  ///   exactly the right topic, and DOES update that class's own tracked
  ///   progress/records on export. Coverage, not the picked term's own
  ///   original topic list, drives what's included: the scheme can
  ///   legitimately spill into a later term's topics (a class that's
  ///   ahead) or fall short of them (a class that's behind) — see
  ///   generateSchemeOfWorkForTerm's own doc comment.
  /// First choice on "Generate Scheme of Work" (2026-09-08, added alongside
  /// [_openSelectOwnTopicsScheme] — see that method's own doc comment):
  /// the normal by-term flow below is completely unchanged past this
  /// point, so picking "By subject, grade/form & term" costs nothing but
  /// one extra tap versus before this was added.
  Future<void> _openSchemeOfWork(BuildContext context) async {
    final mode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Generate Scheme of Work'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('normal'),
            child: const ListTile(
              leading: Icon(Icons.event_note_outlined),
              title: Text('By subject, grade/form & term'),
              subtitle: Text('The usual way — one term at a time'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('own_topics'),
            child: const ListTile(
              leading: Icon(Icons.playlist_add_check),
              title: Text('Select Own Topics Scheme'),
              subtitle: Text(
                'Pick any topics or sub-topics from anywhere across the whole subject — '
                'e.g. to review/re-teach specific topics winding down a final year',
              ),
            ),
          ),
        ],
      ),
    );
    if (mode == null || !context.mounted) return;
    if (mode == 'own_topics') {
      await _openSelectOwnTopicsScheme(context);
      return;
    }

    final selection = await Navigator.of(context).push<TermSelection>(
      MaterialPageRoute(
        builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Generate Scheme of Work', pickTerm: true),
      ),
    );
    if (selection == null || !context.mounted) return;

    final isOneOff = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('One off scheme of work?'),
        content: const Text(
          "A one-off scheme isn't tied to any class: pick any topic to start it from, no class name "
          "needed, and it won't affect any class's tracked progress or this app's own records.\n\n"
          'Choose "No, for a class" to generate one tied to a specific class instead, resuming from (or '
          "updating) that class's own real progress.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('No, for a class'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Yes, one-off'),
          ),
        ],
      ),
    );
    if (isOneOff == null || !context.mounted) return;

    if (isOneOff) {
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
      // For a class with no real recorded progress yet (topicId null),
      // this is what makes the generated scheme use exactly the picked
      // term's OWN authored topics rather than front-loaded coverage from
      // the whole syllabus — see generateSchemeOfWorkForTerm's own doc
      // comment for the real reported "No topics left to place in this
      // term" bug this fixes. Ignored once this class has a real resume
      // point (coverage/spillover correctly takes over from there).
      term: selection.term,
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

  /// "Select Own Topics Scheme" (2026-09-08, per explicit request): lets a
  /// teacher build a scheme from ANY topics/sub-topics they pick themselves
  /// across a subject's whole Grade 10–12 (OBC) or Form 1–4 (CBC) range,
  /// rather than being confined to one grade/term's own authored topic
  /// list — for a Teacher/Lecturer winding down a final year who needs to
  /// review or re-teach very specific topics, not necessarily in their
  /// original syllabus order or all from the same grade/form.
  ///
  /// Always a one-off (see [SchemeOfWorkDocumentScreen.classLabel]): a pick
  /// spanning several real grades/terms has no single real class progress
  /// record it could legitimately update. [SyllabusTemplate.grade] here is
  /// synthetic (id -1, not a real database row) — it exists only to label
  /// the document header/share subject with the real range of grades the
  /// picks were drawn from ("Form 1–Form 4 (Selected Topics)"); curriculum
  /// and subject are the real, shared rows every loaded grade/form already
  /// points at (see database_helper.dart's `_getOrCreate` — subjects are
  /// looked up/shared by curriculum+code, never duplicated per grade file).
  Future<void> _openSelectOwnTopicsScheme(BuildContext context) async {
    final templates = await Navigator.of(context).push<List<SyllabusTemplate>>(
      MaterialPageRoute(builder: (_) => const SelectOwnTopicsSubjectPickerScreen()),
    );
    if (templates == null || templates.isEmpty || !context.mounted) return;

    final entries = await Navigator.of(context).push<List<SchemeOfWorkEntry>>(
      MaterialPageRoute(builder: (_) => SelectOwnTopicsScreen(templates: templates)),
    );
    if (entries == null || entries.isEmpty || !context.mounted) return;

    final sorted = [...templates]..sort((a, b) => a.grade.level.compareTo(b.grade.level));
    final gradeLabel = sorted.length == 1
        ? '${sorted.first.grade.name} (Selected Topics)'
        : '${sorted.first.grade.name}–${sorted.last.grade.name} (Selected Topics)';

    final first = templates.first;
    final syntheticTemplate = SyllabusTemplate(
      curriculum: first.curriculum,
      subject: first.subject,
      grade: Grade(
        id: -1,
        curriculumId: first.curriculum.id,
        name: gradeLabel,
        code: '${first.subject.code}_CUSTOM',
        level: sorted.first.grade.level,
      ),
      terms: const [],
    );

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SchemeOfWorkDocumentScreen(
        template: syntheticTemplate,
        entries: entries,
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
                const CdcNewMaterialsBanner(),
                // Home button order (2026-09-08, per explicit request):
                // Data Manager / Scan Marker / Assignments, Exams & Test
                // Submissions were moved up to be buttons #3/#4/#5
                // specifically — previously scattered across the
                // Public Access Libraries/Data Manager/Admin Tools sections
                // below. Those sections' own labelled headers are removed
                // along with this reorder rather than left pointing at a
                // now-scattered, no-longer-contiguous set of buttons — every
                // function below keeps its exact prior behaviour, only its
                // position (and the section labels) changed.
                FunctionButton(
                  icon: Icons.assignment_outlined,
                  label: 'Generate Lesson Plan',
                  subtitle: 'New lesson, or resume one that was paused',
                  onTap: () => _openLessonPlan(context),
                ),
                FunctionButton(
                  icon: Icons.event_note_outlined,
                  label: 'Generate Scheme of Work',
                  subtitle: 'Pick a subject, grade/form, and term — or select your own topics',
                  onTap: () => _openSchemeOfWork(context),
                ),
                FunctionButton(
                  icon: Icons.folder_shared_outlined,
                  label: 'Data Manager',
                  subtitle: 'Grade Teacher — class roster, Broad Mark Sheet, and report forms',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DataManagerMenuScreen()),
                  ),
                ),
                FunctionButton(
                  icon: Icons.document_scanner_outlined,
                  label: 'Scan Marker',
                  subtitle: 'Marking assistant — capture and queue student scripts for AI-assisted grading (early build)',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MarkingQueueScreen()),
                  ),
                ),
                FunctionButton(
                  icon: Icons.assignment_turned_in_outlined,
                  label: 'Assignments, Exams & Test Submissions',
                  subtitle: 'Send a handwritten assignment or test to your teacher',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AssignmentsTestsMenuScreen()),
                  ),
                ),
                FunctionButton(
                  icon: Icons.calendar_view_week_outlined,
                  label: 'Timetable',
                  subtitle: 'Your schedule, browse by teacher, or manage School Network setup',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TimetableHomeScreen()),
                  ),
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
                  icon: Icons.edit_document,
                  label: 'Handwriting to Word Document Conversion',
                  subtitle: 'Photograph or upload a handwritten page, get back an editable Word document',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HandwritingToWordScreen()),
                  ),
                ),
                // Combined (2026-09-08, per explicit request) — Minutes
                // Maker and Word ↔ PDF Converter used to be two separate
                // home-screen buttons; each keeps its exact prior function,
                // completely separate from the other, just reached one tap
                // further in now (same pattern already used for Teaching
                // Modules/Syllabi/Past Papers and Assignments/Tests above).
                FunctionButton(
                  icon: Icons.groups_outlined,
                  label: 'Minutes Maker & Word ↔ PDF Converter',
                  subtitle: 'Meeting minutes from handwritten notes, and .docx ↔ PDF conversion',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const OfficeToolsMenuScreen()),
                  ),
                ),
                // "Standby" voice command (2026-09-08, per explicit
                // request): moved from a floating action button (which sat
                // over the button list) to the last home button in the
                // hierarchy — a real button like every other function here,
                // not a persistent overlay — while this feature is still
                // being refined to cover more of the app's own functions
                // (see VoiceCommandScreen's own doc comment).
                FunctionButton(
                  icon: Icons.mic_none,
                  label: 'Voice Command',
                  subtitle: 'Tap and speak a command',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const VoiceCommandScreen()),
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
