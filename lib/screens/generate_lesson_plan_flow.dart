import 'package:flutter/material.dart';

import '../models/lesson_checkpoint.dart';
import '../models/lesson_plan.dart';
import '../models/lesson_stage.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/lesson_checkpoint_repository.dart';
import '../services/progress_repository.dart';
import 'lesson_plan_screen.dart';
import 'topic_picker_screen.dart';

/// Orchestrates the "Generate Lesson Plan" entry point end to end: asks
/// whether to start a new lesson (the one after whatever was last
/// concluded in this subject) or resume one that was paused mid-lesson,
/// then — for a new lesson — asks which of the three stages
/// (Introduction/Development/Conclusion) to start from, before opening
/// [LessonPlanScreen]. Resuming reuses that screen's own checkpoint dialog
/// (which already shows the real stage that was reached) rather than
/// asking the stage question twice.
Future<void> startGenerateLessonPlanFlow(
  BuildContext context,
  SyllabusTemplate template, {
  ProgressRepository? progressRepository,
  LessonCheckpointRepository? checkpointRepository,
}) async {
  final progress = progressRepository ?? ProgressRepository();
  final checkpoints = checkpointRepository ?? LessonCheckpointRepository();

  final choice = await showDialog<_LessonPlanStart>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Generate lesson plan'),
      content: const Text(
        'Write a new lesson plan for the topic after the last one you generated a plan for in '
        'this subject, or resume one that was paused partway through?',
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
            checkpointRepository: checkpoints,
          ),
        ));
        return;
      }
    }
  }

  // New lesson: the topic after whatever was last concluded in this
  // subject (same cursor the Scheme of Work screen uses), falling back to
  // the very first topic if nothing's been concluded yet.
  final lastConcluded = await progress.getLastConcludedTopicId(
    curriculumCode: template.curriculum.code,
    subjectCode: template.subject.code,
    gradeLevel: template.grade.level,
  );
  if (!context.mounted) return;
  final upcoming = generateSchemeOfWork(template, lastConcluded);

  SchemeOfWorkEntry? entry;
  if (upcoming.isNotEmpty) {
    entry = upcoming.first;
  } else if (context.mounted) {
    // Every topic is already marked concluded — let the teacher pick one
    // manually rather than a dead end.
    entry = await Navigator.of(context).push<SchemeOfWorkEntry>(
      MaterialPageRoute(builder: (_) => TopicPickerScreen(template: template)),
    );
  }
  if (entry == null || !context.mounted) return;

  final stage = await showDialog<LessonStage>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Start the lesson plan from'),
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
      entry: entry!,
      checkpointRepository: checkpoints,
      initialFocusStageIndex: chosenStage.indexIn(defaultCdcLessonPlanTemplate.progressionStages),
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
