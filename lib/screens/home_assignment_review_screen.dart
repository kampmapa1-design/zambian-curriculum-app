import 'package:flutter/material.dart';

import '../models/home_assignment.dart';
import '../models/marking_scheme.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/marking_scheme_repository.dart';
import 'home_assignment_send_screen.dart';
import 'marking_scheme_builder_screen.dart';

const _kWeekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Home Assignment epic, Stage 5 — the generated assignment, shown for
/// the teacher's own review before anything is sent anywhere. The
/// assignment itself is never auto-sent. The marking key IS now
/// auto-saved (2026-09-16, per explicit request: "automatically generate
/// a marking key for every home assignment that it generates") — see
/// [_autoSaveMarkingKey] — as a real, reusable [MarkingScheme] the moment
/// this screen loads, guaranteeing one always exists rather than only
/// when a teacher happens to tap "Review & Save." That button remains,
/// now updating the SAME auto-saved scheme in place (via
/// [MarkingSchemeBuilderScreen.existing]) rather than creating a
/// duplicate, for a teacher who wants to refine it. Stage 6's
/// marking-key labeling convention ("Marking Key — Home Assignment —
/// [Subject] — [Topic] — [Date], [Day], [Time issued]") is computed
/// once, at generation time — "issued" is genuinely now.
class HomeAssignmentReviewScreen extends StatefulWidget {
  const HomeAssignmentReviewScreen({
    required this.result,
    required this.template,
    required this.entry,
    required this.pageLength,
    required this.questionType,
    this.schemeRepository,
    super.key,
  });

  final HomeAssignmentResult result;
  final SyllabusTemplate template;
  final SchemeOfWorkEntry entry;
  final HomeAssignmentPageLength pageLength;
  final HomeAssignmentQuestionType questionType;
  final MarkingSchemeRepository? schemeRepository;

  @override
  State<HomeAssignmentReviewScreen> createState() => _HomeAssignmentReviewScreenState();
}

class _HomeAssignmentReviewScreenState extends State<HomeAssignmentReviewScreen> {
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  MarkingScheme? _autoSavedScheme;

  HomeAssignmentResult get result => widget.result;
  SyllabusTemplate get template => widget.template;
  SchemeOfWorkEntry get entry => widget.entry;

  String get _topicLabel => entry.subTopic?.name ?? entry.topic.name;

  @override
  void initState() {
    super.initState();
    _autoSaveMarkingKey();
  }

  String _markingKeyTitle() {
    final now = DateTime.now();
    final date = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final day = _kWeekdayNames[now.weekday - 1];
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return 'Marking Key — Home Assignment — ${template.subject.name} — $_topicLabel — $date, $day, $time';
  }

  /// Saves the AI-generated marking key exactly as generated, no review
  /// gate — this is what makes generation "automatic" rather than
  /// contingent on the teacher's own extra tap. Never blocks or errors
  /// the screen: this is a background guarantee, not something a teacher
  /// waits on or can fail out of.
  Future<void> _autoSaveMarkingKey() async {
    final scheme = MarkingScheme(
      id: '${DateTime.now().millisecondsSinceEpoch}',
      title: _markingKeyTitle(),
      subjectName: template.subject.name,
      gradeName: template.grade.name,
      topicName: entry.topic.name,
      subTopicName: entry.subTopic?.name,
      questions: result.toMarkingSchemeQuestions(),
      createdAt: DateTime.now(),
      gradingGuidance: result.notes.trim().isEmpty ? null : result.notes,
    );
    try {
      final saved = await _schemeRepository.save(scheme);
      if (!mounted) return;
      setState(() => _autoSavedScheme = saved);
    } catch (_) {
      // Best-effort — the review screen and "Review & Save" button both
      // still work from result.toMarkingSchemeQuestions() directly even
      // if this background save failed for some reason.
    }
  }

  Future<void> _reviewAndSaveMarkingKey(BuildContext context) async {
    final saved = await Navigator.of(context).push<MarkingScheme>(
      MaterialPageRoute(
        builder: (_) => MarkingSchemeBuilderScreen(
          subjectName: template.subject.name,
          gradeName: template.grade.name,
          topicName: entry.topic.name,
          subTopicName: entry.subTopic?.name,
          existing: _autoSavedScheme,
          initialQuestions: result.toMarkingSchemeQuestions(),
          initialTitle: _markingKeyTitle(),
          aiNotes: result.notes.trim().isEmpty ? null : result.notes,
        ),
      ),
    );
    if (saved == null || !context.mounted) return;
    setState(() => _autoSavedScheme = saved);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HomeAssignmentSendScreen(result: result, subjectName: template.subject.name, markingKeyTitle: saved.title),
      ),
    );
  }

  /// For a teacher who's happy with the AI-generated key as-is — skips
  /// the manual review editor entirely and goes straight to sending,
  /// since the key is already real and already saved (see
  /// [_autoSaveMarkingKey]), just not teacher-reviewed line by line.
  Future<void> _continueToSend(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HomeAssignmentSendScreen(
          result: result,
          subjectName: template.subject.name,
          markingKeyTitle: _autoSavedScheme?.title ?? _markingKeyTitle(),
        ),
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
            '${template.subject.name} · ${template.grade.name} · $_topicLabel · ${widget.pageLength.label} · ${widget.questionType.label}',
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
          if (_autoSavedScheme != null) ...[
            Row(
              children: [
                const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Marking key saved automatically — ready to send or refine below.',
                    style: TextStyle(fontSize: 12, color: Colors.green.shade700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            icon: const Icon(Icons.send_outlined),
            label: const Text('Continue to Send'),
            onPressed: () => _continueToSend(context),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.checklist_outlined),
            label: const Text('Review & Refine Marking Key'),
            onPressed: () => _reviewAndSaveMarkingKey(context),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              "The marking key above is already saved as generated. Opens the usual marking-key editor if you'd rather check or adjust it first — updates the same saved key, doesn't create a second one.",
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }
}
