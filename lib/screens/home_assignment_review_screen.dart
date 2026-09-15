import 'package:flutter/material.dart';

import '../models/home_assignment.dart';
import '../models/marking_scheme.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import 'home_assignment_send_screen.dart';
import 'marking_scheme_builder_screen.dart';

const _kWeekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Home Assignment epic, Stage 5 — the generated assignment, shown for
/// the teacher's own review (never auto-sent, never auto-saved) before
/// anything happens with it. Stage 6's marking-key labeling convention
/// ("Marking Key — Home Assignment — [Subject] — [Topic] — [Date], [Day],
/// [Time issued]") is computed here, at the moment the teacher chooses to
/// build the key — "issued" is genuinely now, not whenever it's
/// eventually sent to learners (Stage 7, not yet built).
class HomeAssignmentReviewScreen extends StatelessWidget {
  const HomeAssignmentReviewScreen({
    required this.result,
    required this.template,
    required this.entry,
    required this.pageLength,
    required this.questionType,
    super.key,
  });

  final HomeAssignmentResult result;
  final SyllabusTemplate template;
  final SchemeOfWorkEntry entry;
  final HomeAssignmentPageLength pageLength;
  final HomeAssignmentQuestionType questionType;

  String get _topicLabel => entry.subTopic?.name ?? entry.topic.name;

  String _markingKeyTitle() {
    final now = DateTime.now();
    final date = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final day = _kWeekdayNames[now.weekday - 1];
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return 'Marking Key — Home Assignment — ${template.subject.name} — $_topicLabel — $date, $day, $time';
  }

  Future<void> _reviewAndSaveMarkingKey(BuildContext context) async {
    final saved = await Navigator.of(context).push<MarkingScheme>(
      MaterialPageRoute(
        builder: (_) => MarkingSchemeBuilderScreen(
          subjectName: template.subject.name,
          gradeName: template.grade.name,
          topicName: entry.topic.name,
          subTopicName: entry.subTopic?.name,
          initialQuestions: result.toMarkingSchemeQuestions(),
          initialTitle: _markingKeyTitle(),
          aiNotes: result.notes.trim().isEmpty ? null : result.notes,
        ),
      ),
    );
    if (saved == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HomeAssignmentSendScreen(result: result, subjectName: template.subject.name, markingKeyTitle: saved.title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home Assignment')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(result.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            '${template.subject.name} · ${template.grade.name} · $_topicLabel · ${pageLength.label} · ${questionType.label}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          if (result.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              color: Colors.amber.shade50,
              child: Padding(padding: const EdgeInsets.all(12), child: Text('AI note: ${result.notes}', style: const TextStyle(fontSize: 12.5))),
            ),
          ],
          const SizedBox(height: 16),
          if (result.instructions.trim().isNotEmpty) ...[
            Text('Instructions', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(result.instructions),
            const SizedBox(height: 16),
          ],
          Text('Questions (${result.totalMarks.toStringAsFixed(result.totalMarks == result.totalMarks.roundToDouble() ? 0 : 1)} marks total)',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final q in result.questions)
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text(q.number)),
                title: Text(q.text),
                trailing: Text('${q.maxMarks.toStringAsFixed(q.maxMarks == q.maxMarks.roundToDouble() ? 0 : 1)} mk${q.maxMarks == 1 ? '' : 's'}'),
              ),
            ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.checklist_outlined),
            label: const Text('Review & Save Marking Key'),
            onPressed: () => _reviewAndSaveMarkingKey(context),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              "Opens the usual marking-key editor, pre-filled from the questions above — nothing is saved until you review and confirm it there.",
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }
}
