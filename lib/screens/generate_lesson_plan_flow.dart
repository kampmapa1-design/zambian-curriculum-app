import 'package:flutter/material.dart';

import '../models/lesson_checkpoint.dart';
import '../models/lesson_plan.dart';
import '../models/lesson_stage.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/lesson_checkpoint_repository.dart';
import 'lesson_plan_screen.dart';
import 'term_topic_picker_screen.dart';

/// Orchestrates the "Generate Lesson Plan" entry point end to end: asks
/// whether to start a new lesson or resume one that was paused mid-lesson.
/// For a new lesson, the teacher picks exactly which topic to teach (via
/// [TermTopicPickerScreen] — Term, then that term's topics by week) and
/// which of the three stages (Introduction/Main Body/Conclusion) this
/// specific lesson plan should cover, before opening [LessonPlanScreen].
/// Resuming reuses that screen's own checkpoint dialog (which already shows
/// the real stage that was reached) rather than asking the stage question
/// twice.
Future<void> startGenerateLessonPlanFlow(
  BuildContext context,
  SyllabusTemplate template, {
  LessonCheckpointRepository? checkpointRepository,
}) async {
  final checkpoints = checkpointRepository ?? LessonCheckpointRepository();

  final choice = await showDialog<_LessonPlanStart>(
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
          ),
        ));
        return;
      }
    }
  }

  // New lesson: let the teacher pick exactly which term/week/topic to
  // teach, rather than auto-advancing to "whatever comes next" — a topic
  // can need several separate lesson plans (one per stage, or per CBC
  // learning point), so there's no single "next" topic to guess at.
  final entry = await Navigator.of(context).push<SchemeOfWorkEntry>(
    MaterialPageRoute(builder: (_) => TermTopicPickerScreen(template: template)),
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

  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => LessonPlanScreen(
      subjectName: template.subject.name,
      curriculumCode: template.curriculum.code,
      subjectCode: template.subject.code,
      gradeLevel: template.grade.level,
      entry: entry,
      template: activeTemplate,
      checkpointRepository: checkpoints,
      focusStage: chosenStage,
    ),
  ));
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
