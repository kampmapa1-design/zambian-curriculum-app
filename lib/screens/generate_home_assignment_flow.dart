import 'package:flutter/material.dart';

import '../models/home_assignment.dart';
import '../services/home_assignment_ai_service.dart';
import 'home_assignment_review_screen.dart';
import 'topic_picker_flow.dart';

/// Home Assignment epic, Stage 5 — "Under 'Assignments, Exams and Test
/// Submission,' add 'Home Assignment' for subject teachers. Reuse the
/// existing subject/grade/topic selection menu (same as Lesson Plan)."
/// Orchestrator function mirroring `startGenerateLessonPlanFlow`'s shape
/// (dialog-driven, one step at a time) but simpler — a Home Assignment is
/// always a fresh generation for one topic, no "resume paused" concept.
Future<void> startGenerateHomeAssignmentFlow(BuildContext context) async {
  final picked = await pickTopicViaTermWeek(context, title: 'Generate Home Assignment');
  if (picked == null || !context.mounted) return;

  final pageLength = await showDialog<HomeAssignmentPageLength>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Prepare a one-page or two-page home assignment?'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(dialogContext).pop(HomeAssignmentPageLength.one),
          child: const ListTile(leading: Icon(Icons.looks_one_outlined), title: Text('One page'), subtitle: Text('A focused, shorter set of questions')),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(dialogContext).pop(HomeAssignmentPageLength.two),
          child: const ListTile(leading: Icon(Icons.looks_two_outlined), title: Text('Two pages'), subtitle: Text('A more substantial set of questions')),
        ),
      ],
    ),
  );
  if (pageLength == null || !context.mounted) return;

  final questionType = await showDialog<HomeAssignmentQuestionType>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Prepare summative or formative questions?'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(dialogContext).pop(HomeAssignmentQuestionType.summative),
          child: const ListTile(leading: Icon(Icons.fact_check_outlined), title: Text('Summative'), subtitle: Text('Tests overall mastery once the topic is taught')),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(dialogContext).pop(HomeAssignmentQuestionType.formative),
          child: const ListTile(leading: Icon(Icons.trending_up_outlined), title: Text('Formative'), subtitle: Text('Checks understanding while still learning')),
        ),
      ],
    ),
  );
  if (questionType == null || !context.mounted) return;

  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(children: [CircularProgressIndicator(), SizedBox(width: 20), Expanded(child: Text('Generating home assignment...'))]),
    ),
  );

  try {
    final result = await HomeAssignmentAiService().generate(
      topic: picked.entry.topic.name,
      subtopic: picked.entry.subTopic?.name,
      subject: picked.template.subject.name,
      grade: picked.template.grade.name,
      competencies: picked.entry.competencies.map((c) => c.description).toList(),
      objectives: picked.entry.objectives.map((o) => o.description).toList(),
      references: picked.entry.references,
      pageLength: pageLength,
      questionType: questionType,
    );
    navigator.pop(); // close the loading dialog
    if (!context.mounted) return;
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => HomeAssignmentReviewScreen(
          result: result,
          template: picked.template,
          entry: picked.entry,
          pageLength: pageLength,
          questionType: questionType,
        ),
      ),
    );
  } on HomeAssignmentAiUnavailable catch (e) {
    navigator.pop();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    navigator.pop();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not generate this home assignment: $e')));
  }
}
