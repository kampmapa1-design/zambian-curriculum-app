import 'package:flutter/material.dart';

import '../models/activity_bank.dart';
import '../models/cdc_constraint_rules.dart';
import '../models/guided_answers.dart';
import '../models/scheme_of_work.dart';
import '../services/guided_planning_engine.dart';
import '../services/guided_planning_repository.dart';
import 'lesson_plan_screen.dart';

/// Stage 5: the offline guided Q&A. After picking topic/sub-topic (already
/// done by the time this screen opens — [entry] carries it), the teacher
/// answers a few structured questions; [GuidedPlanningEngine] adjusts the
/// suggested activities and group size, validating every adjustment
/// against [CdcConstraintRuleSet] so nothing mandatory can be dropped.
///
/// Only offers itself where a real, sourced activity bank exists for this
/// sub-topic (see assets/activity_banks/) — it does not fabricate
/// activities for topics that don't have one yet.
class GuidedPlanningScreen extends StatefulWidget {
  const GuidedPlanningScreen({
    super.key,
    required this.subjectName,
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.entry,
    this.repository,
    this.engine,
  });

  final String subjectName;
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final SchemeOfWorkEntry entry;
  final GuidedPlanningRepository? repository;
  final GuidedPlanningEngine? engine;

  @override
  State<GuidedPlanningScreen> createState() => _GuidedPlanningScreenState();
}

class _GuidedPlanningScreenState extends State<GuidedPlanningScreen> {
  late final GuidedPlanningRepository _repository = widget.repository ?? GuidedPlanningRepository();
  late final GuidedPlanningEngine _engine = widget.engine ?? GuidedPlanningEngine();

  bool _loading = true;
  ActivityBank? _bank;
  CdcConstraintRuleSet? _ruleSet;

  final _classSizeController = TextEditingController();
  bool? _teachingAidsAvailable;
  PriorMastery? _priorMastery;
  ActivityStylePreference _preferredStyle = ActivityStylePreference.noPreference;

  GuidedPlanningResult? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _classSizeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final subTopicName = widget.entry.subTopic?.name ?? widget.entry.topic.name;
    final bank = await _repository.loadBankFor(
      curriculumCode: widget.curriculumCode,
      subjectCode: widget.subjectCode,
      subTopicName: subTopicName,
    );
    final ruleSet = bank == null ? null : await _repository.loadRulesFor(widget.curriculumCode);
    if (!mounted) return;
    setState(() {
      _bank = bank;
      _ruleSet = ruleSet;
      _loading = false;
    });
  }

  void _generate() {
    if (_bank == null || _ruleSet == null) return;
    final classSize = int.tryParse(_classSizeController.text.trim());
    final result = _engine.apply(
      bank: _bank!,
      ruleSet: _ruleSet!,
      answers: GuidedAnswers(
        classSize: classSize,
        teachingAidsAvailable: _teachingAidsAvailable,
        priorMastery: _priorMastery,
        preferredStyle: _preferredStyle,
      ),
    );
    setState(() => _result = result);
  }

  void _useInLessonPlan() {
    final result = _result;
    if (result == null) return;
    final activitiesText = result.selectedActivities
        .map((a) => '${a.description}\nMaterials: ${a.materials}')
        .join('\n\n');
    final noteLines = <String>[
      if (result.suggestedGroupSize != null) 'Suggested group size: ${result.suggestedGroupSize} learners.',
      for (final n in result.notices)
        '${n.severity == PlanningNoticeSeverity.block ? "Blocked" : "Note"}: ${n.message}',
    ];
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LessonPlanScreen(
        subjectName: widget.subjectName,
        curriculumCode: widget.curriculumCode,
        subjectCode: widget.subjectCode,
        gradeLevel: widget.gradeLevel,
        entry: widget.entry,
        guidedActivitiesText: activitiesText,
        guidedNoteText: noteLines.isEmpty ? null : noteLines.join('\n'),
      ),
    ));
  }

  void _openPlainLessonPlan() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LessonPlanScreen(
        subjectName: widget.subjectName,
        curriculumCode: widget.curriculumCode,
        subjectCode: widget.subjectCode,
        gradeLevel: widget.gradeLevel,
        entry: widget.entry,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Guided Planning')),
      body: _loading ? const Center(child: CircularProgressIndicator()) : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_bank == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Guided planning isn\'t available yet for "${widget.entry.title}" — no activity bank has '
              'been sourced for it yet. It currently only covers History Form 1 → 1.1 Introduction to '
              'History → 1.1.1 Reasons for Learning History.',
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _openPlainLessonPlan, child: const Text('Open Lesson Plan instead')),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_bank!.source != null) ...[
          Text(_bank!.source!, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
          const SizedBox(height: 16),
        ],
        TextFormField(
          controller: _classSizeController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Class size', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        Text('Are teaching aids/materials available for this lesson?', style: Theme.of(context).textTheme.labelLarge),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Available')),
            ButtonSegment(value: false, label: Text('None available')),
          ],
          selected: _teachingAidsAvailable == null ? {} : {_teachingAidsAvailable!},
          emptySelectionAllowed: true,
          onSelectionChanged: (s) => setState(() => _teachingAidsAvailable = s.isEmpty ? null : s.first),
        ),
        const SizedBox(height: 16),
        Text('Learners\' prior mastery of this sub-topic', style: Theme.of(context).textTheme.labelLarge),
        SegmentedButton<PriorMastery>(
          segments: const [
            ButtonSegment(value: PriorMastery.low, label: Text('Low')),
            ButtonSegment(value: PriorMastery.medium, label: Text('Medium')),
            ButtonSegment(value: PriorMastery.high, label: Text('High')),
          ],
          selected: _priorMastery == null ? {} : {_priorMastery!},
          emptySelectionAllowed: true,
          onSelectionChanged: (s) => setState(() => _priorMastery = s.isEmpty ? null : s.first),
        ),
        const SizedBox(height: 16),
        Text('Preferred activity style', style: Theme.of(context).textTheme.labelLarge),
        SegmentedButton<ActivityStylePreference>(
          segments: const [
            ButtonSegment(value: ActivityStylePreference.groupWork, label: Text('Group work')),
            ButtonSegment(value: ActivityStylePreference.individual, label: Text('Individual')),
            ButtonSegment(value: ActivityStylePreference.noPreference, label: Text('No preference')),
          ],
          selected: {_preferredStyle},
          onSelectionChanged: (s) => setState(() => _preferredStyle = s.first),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _generate,
          icon: const Icon(Icons.rule),
          label: const Text('Generate suggestions'),
        ),
        if (_result != null) ..._buildResult(context, _result!),
      ],
    );
  }

  List<Widget> _buildResult(BuildContext context, GuidedPlanningResult result) {
    return [
      const Divider(height: 32),
      if (result.suggestedGroupSize != null) ...[
        Text('Suggested group size: ${result.suggestedGroupSize} learners',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
      ],
      Text('Suggested activities', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      for (final a in result.selectedActivities)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.description),
                const SizedBox(height: 4),
                Text('Materials: ${a.materials}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      if (result.notices.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Rule notices', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        for (final n in result.notices)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  n.severity == PlanningNoticeSeverity.block ? Icons.block : Icons.info_outline,
                  size: 18,
                  color: n.severity == PlanningNoticeSeverity.block
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(n.message)),
              ],
            ),
          ),
      ],
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _useInLessonPlan,
        icon: const Icon(Icons.assignment_outlined),
        label: const Text('Use in Lesson Plan'),
      ),
    ];
  }
}
