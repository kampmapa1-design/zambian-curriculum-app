import 'package:flutter/material.dart';

import '../models/lesson_checkpoint.dart';
import '../models/lesson_plan.dart';
import '../models/lesson_stage.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/lesson_checkpoint_repository.dart';
import '../services/teacher_profile_repository.dart';
import 'class_resume_picker_screen.dart';
import 'lesson_plan_screen.dart';
import 'term_topic_picker_screen.dart';

/// Orchestrates the "Generate Lesson Plan" entry point end to end: asks
/// whether to start a new lesson or resume one that was paused mid-lesson.
///
/// For a new lesson, the teacher first answers "One off lesson plan?"
/// (2026-09-06, per explicit request — a standalone alternative alongside
/// everything below, not a replacement for it):
/// - **No** (unchanged from before this question existed): "which class,
///   and where did it reach?" (via [ClassResumePickerScreen] — the exact
///   same step [HomeScreen]'s "Generate Scheme of Work" already asks,
///   reused here rather than duplicated) so the topic picker that follows
///   shows THAT class's own real term/week placement instead of always a
///   fresh class's (see [schemeOfWorkTermWindowsFrom]'s own doc comment
///   for why the two can otherwise disagree).
/// - **Yes**: skips the class question entirely — the topic picker falls
///   back to its own fresh-class default, the Class field is left blank
///   (see `_askTeacherProfile`'s own doc comment), and nothing about this
///   lesson is logged to this app's own records (see [LessonPlanScreen
///   .isOneOff]) — a document produced without needing to connect it to
///   any class's tracked progress.
///
/// Either way, the teacher then picks exactly which topic to teach (via
/// [TermTopicPickerScreen] — Term, then that term's topics by week) and
/// which of the three stages (Introduction/Main Body/Conclusion) this
/// specific lesson plan should cover, before opening [LessonPlanScreen].
/// Resuming reuses that screen's own checkpoint dialog (which already
/// shows the real stage that was reached) rather than asking the stage
/// question twice, and skips both the one-off and class-resume questions
/// entirely — a paused lesson resumes by its own saved checkpoint
/// (carrying forward whichever of the two it was originally started as,
/// see [LessonCheckpoint.isOneOff]), not by asking either question again.
///
/// [initialEntry] (2026-09-08, voice commands — see VoiceCommandResolver):
/// when given, this is already a specific, resolved topic/sub-topic to
/// teach — the "resume paused lesson?" question and the term/topic picker
/// are both skipped entirely (there is nothing left to resume from or
/// pick, the command already named it), going straight into a NEW lesson
/// for that exact entry. Every other question (one-off vs class, which
/// stage, teacher details) is still asked exactly as normal — voice only
/// ever answers what it was actually told (subject/grade/topic/week), it
/// never guesses the rest.
Future<void> startGenerateLessonPlanFlow(
  BuildContext context,
  SyllabusTemplate template, {
  LessonCheckpointRepository? checkpointRepository,
  SchemeOfWorkEntry? initialEntry,
}) async {
  final checkpoints = checkpointRepository ?? LessonCheckpointRepository();

  final choice = initialEntry != null
      ? _LessonPlanStart.next
      : await showDialog<_LessonPlanStart>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Generate lesson plan'),
      content: const Text(
        'Pick a term, week and topic to write a new lesson plan, or resume one that was paused '
        'partway through?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(_LessonPlanStart.resume),
          child: const Text('Resume paused lesson'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(_LessonPlanStart.next),
          child: const Text('New lesson plan'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;

  // OBC (2013) and CBC (2023) use structurally different real lesson plan
  // templates — see defaultCbcLessonPlanTemplate's doc comment.
  final activeTemplate =
      template.curriculum.code == 'CBC_2023' ? defaultCbcLessonPlanTemplate : defaultCdcLessonPlanTemplate;

  if (choice == _LessonPlanStart.resume) {
    final checkpoint = await checkpoints.findMostRecentForSubject(
      curriculumCode: template.curriculum.code,
      subjectCode: template.subject.code,
      gradeLevel: template.grade.level,
    );
    if (!context.mounted) return;
    if (checkpoint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No paused lesson found for this subject yet — starting a new one instead.')),
      );
    } else {
      final entry = _entryForCheckpoint(template, checkpoint);
      if (entry == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't find that lesson's topic anymore — starting a new one instead.")),
        );
      } else {
        // LessonPlanScreen's own initState checks for a saved checkpoint on
        // this exact topic and asks "Resume this lesson?", showing the real
        // stage that was reached — no need to ask again here.
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => LessonPlanScreen(
            subjectName: template.subject.name,
            curriculumCode: template.curriculum.code,
            subjectCode: template.subject.code,
            gradeLevel: template.grade.level,
            entry: entry,
            template: activeTemplate,
            checkpointRepository: checkpoints,
            isOneOff: checkpoint.isOneOff,
          ),
        ));
        return;
      }
    }
  }

  // New lesson: "One off lesson plan?" (2026-09-06, per explicit request)
  // — asked before anything class-related, so a one-off never needs a
  // class question at all. See isOneOff's own branches below for exactly
  // what each answer skips.
  final isOneOff = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('One off lesson plan?'),
      content: const Text(
        "A one-off lesson plan isn't tied to any class: pick any topic to write it for, no class name "
        "needed (the Class field is simply left blank), and it won't affect any class's tracked progress "
        "or this app's own records.\n\n"
        'Choose "No, for a class" to generate one tied to a specific class instead, using that class\'s '
        'own real progress to place it in the right term and week.',
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

  List<List<SchemeOfWorkEntry>>? classWindows;
  String? defaultClassLabel;

  if (!isOneOff && initialEntry == null) {
    // "Which class, and where did it reach?" (2026-09-06) — the same
    // question Scheme of Work generation already asks, via the very same
    // screen, so the topic/week picker that follows can show THIS class's
    // own real placement rather than always a fresh class's. Never
    // skipped for a class-tracked lesson, same as Scheme of Work's own
    // flow, for the same reason (see ClassResumePickerScreen's own doc
    // comment): a lesson plan generated for a colleague's class must
    // never silently get confused with — or overwrite — the teacher's own
    // regular class's real progress record.
    final resume = await Navigator.of(context).push<ClassResumeSelection>(
      MaterialPageRoute(builder: (_) => ClassResumePickerScreen(template: template)),
    );
    if (resume == null || !context.mounted) return;
    classWindows = schemeOfWorkTermWindowsFrom(
      template,
      resume.topicId,
      lastConcludedSubTopicId: resume.subTopicId,
    );
    defaultClassLabel = resume.classLabel;
  }
  // isOneOff: classWindows stays null, so TermTopicPickerScreen falls back
  // to its own default fresh-class windows below — exactly right, since a
  // one-off has no class whose real progress could place it any more
  // precisely than that.

  // Let the teacher pick exactly which term/week/topic to teach, rather
  // than auto-advancing to "whatever comes next" — a topic can need
  // several separate lesson plans (one per stage, or per CBC learning
  // point), so there's no single "next" topic to guess at. Skipped
  // entirely when [initialEntry] already names one (voice commands) — see
  // this function's own doc comment.
  final entry = initialEntry ??
      await Navigator.of(context).push<SchemeOfWorkEntry>(
        MaterialPageRoute(builder: (_) => TermTopicPickerScreen(template: template, windows: classWindows)),
      );
  if (entry == null || !context.mounted) return;

  final stage = await showDialog<LessonStage>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Which part of this lesson should the plan cover?'),
      children: [
        for (final s in LessonStage.values)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(s),
            child: Text(s.label),
          ),
      ],
    ),
  );
  if (!context.mounted) return;
  final chosenStage = stage ?? LessonStage.introduction;

  // Asked right here — subject and topic are both chosen, this is the
  // "appropriate place" per explicit request — and remembered from then on
  // (see TeacherProfileRepository), so a teacher only ever types their own
  // name/school once; class name still pre-fills but stays editable per
  // lesson, since one teacher can cover more than one class. Pre-fills from
  // the class just picked above (2026-09-06) rather than whatever class
  // name happened to be saved last time — this lesson plan is already
  // known to be for THAT class specifically. For a one-off, the Class
  // field is left blank instead (see _askTeacherProfile's own doc comment)
  // and never persisted back to the remembered profile.
  final profile = await _askTeacherProfile(context, defaultClassLabel: defaultClassLabel, isOneOff: isOneOff);
  if (!context.mounted) return;

  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => LessonPlanScreen(
      subjectName: template.subject.name,
      curriculumCode: template.curriculum.code,
      subjectCode: template.subject.code,
      gradeLevel: template.grade.level,
      entry: entry,
      isOneOff: isOneOff,
      template: activeTemplate,
      checkpointRepository: checkpoints,
      focusStage: chosenStage,
      teacherProfile: profile,
    ),
  ));
}

/// Asks for the teacher's name/school/(this lesson's) class, pre-filled
/// from whatever was saved last time — real, reported gap fixed
/// 2026-09-03: these details never came from the syllabus/scheme of work
/// the way Subject/Topic do, so nothing previously prompted for them at
/// all; a teacher had to notice the header fields buried in the lesson
/// plan form itself and remember to fill them in every single time.
/// Skippable (leaves whatever's already saved untouched) since none of
/// these are required to generate a usable lesson plan.
///
/// [defaultClassLabel], when non-empty, pre-fills the class field instead
/// of whatever class name was saved last time (2026-09-06) — this lesson
/// is already known to be for that specific class, from the class-resume
/// step just answered above. Ignored when [isOneOff] is true.
///
/// [isOneOff] (2026-09-06, per explicit request): leaves the Class field
/// BLANK instead — a one-off lesson plan needs no class name at all — but
/// still fully editable, so a teacher who wants to note something for a
/// one-off print (e.g. "printing for Mr. Banda") still can. Whatever ends
/// up in that field for a one-off is used on THIS document only and is
/// never written back to the remembered profile (name/school still are,
/// same as any other time this dialog is used) — a one-off's own "leave
/// it empty, don't affect the app's records" principle would otherwise be
/// undermined by silently overwriting the teacher's own regular
/// class-name default the very next time this dialog opens.
Future<TeacherProfile?> _askTeacherProfile(
  BuildContext context, {
  String? defaultClassLabel,
  bool isOneOff = false,
}) async {
  final repository = TeacherProfileRepository();
  final saved = await repository.load();
  if (!context.mounted) return saved;

  final resolvedClassName = isOneOff
      ? ''
      : (defaultClassLabel != null && defaultClassLabel.trim().isNotEmpty)
          ? defaultClassLabel.trim()
          : saved.className;

  final nameController = TextEditingController(text: saved.name);
  final schoolController = TextEditingController(text: saved.school);
  final classController = TextEditingController(text: resolvedClassName);

  final result = await showDialog<TeacherProfile>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Your details'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Shown at the top of the lesson plan, alongside Subject/Topic. Remembered for next '
                'time — edit any time from the lesson plan itself.'),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Your name', border: OutlineInputBorder()),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: schoolController,
              decoration: const InputDecoration(labelText: 'School name', border: OutlineInputBorder()),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: classController,
              decoration: const InputDecoration(labelText: 'Class (e.g. "10A")', border: OutlineInputBorder()),
              textCapitalization: TextCapitalization.words,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          // One-off: Skip must still leave the Class field blank for THIS
          // document (see isOneOff's own doc comment) — popping `saved`
          // verbatim here would silently bring back whatever class name
          // was remembered from a previous, non-one-off lesson.
          onPressed: () => Navigator.of(dialogContext).pop(isOneOff ? saved.copyWith(className: '') : saved),
          child: const Text('Skip'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(TeacherProfile(
            name: nameController.text.trim(),
            school: schoolController.text.trim(),
            className: classController.text.trim(),
          )),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  nameController.dispose();
  schoolController.dispose();
  classController.dispose();

  final profile = result ?? saved;
  if (result != null) {
    // One-off: name/school are still the teacher's own real, persistent
    // details, worth remembering as always — but the class text (even
    // blank, even something explicitly typed for this one-off print)
    // must never overwrite the remembered profile's own class name, per
    // isOneOff's own doc comment above.
    await repository.save(isOneOff ? profile.copyWith(className: saved.className) : profile);
  }
  return profile;
}

enum _LessonPlanStart { next, resume }

/// Rebuilds a [SchemeOfWorkEntry] for whichever topic/sub-topic a saved
/// checkpoint points at, by id-matching against the current template — the
/// checkpoint itself only stores ids, not the syllabus objects. Returns
/// null if that topic can't be found anymore (e.g. bundled content changed).
SchemeOfWorkEntry? _entryForCheckpoint(SyllabusTemplate template, LessonCheckpoint checkpoint) {
  for (final term in template.terms) {
    for (final topic in term.topics) {
      if (topic.id != checkpoint.topicId) continue;
      if (checkpoint.subTopicId == null) {
        return SchemeOfWorkEntry(
          weekNumber: 1,
          topic: topic,
          objectives: topic.objectives,
          competencies: topic.competencies,
        );
      }
      for (final subTopic in topic.subTopics) {
        if (subTopic.id == checkpoint.subTopicId) {
          return SchemeOfWorkEntry(
            weekNumber: 1,
            topic: topic,
            subTopic: subTopic,
            objectives: subTopic.objectives,
            competencies: subTopic.competencies,
          );
        }
      }
    }
  }
  return null;
}
