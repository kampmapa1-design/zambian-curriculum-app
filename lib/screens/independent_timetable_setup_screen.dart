import 'package:flutter/material.dart';

import '../models/independent_timetable_project.dart';
import '../models/timetable.dart';
import '../services/independent_timetable_service.dart';
import '../services/school_service.dart' show SchoolException;
import 'independent_timetable_generated_screen.dart';

/// "Build Timetable for Another School" (added 2026-09-16) — day
/// structure, subject periods/week, and the practical-subjects
/// exception list for one independent project. Deliberately mirrors
/// [TimetableSetupScreen] field-for-field (same [TimetableConfig] model,
/// same double-period rule) — the two features are meant to feel
/// identical to use; only which project they save against differs.
class IndependentTimetableSetupScreen extends StatefulWidget {
  const IndependentTimetableSetupScreen({required this.project, super.key});
  final IndependentTimetableProject project;

  @override
  State<IndependentTimetableSetupScreen> createState() => _IndependentTimetableSetupScreenState();
}

class _IndependentTimetableSetupScreenState extends State<IndependentTimetableSetupScreen> {
  final _service = IndependentTimetableService();
  bool _loading = true;
  bool _saving = false;
  bool _generating = false;

  late final _periodsPerDayController = TextEditingController();
  late final _periodLengthController = TextEditingController();
  late final _teachingDaysController = TextEditingController();
  late final _maxDailyLoadController = TextEditingController();
  final _newSubjectController = TextEditingController();
  final _newExceptionController = TextEditingController();

  final Map<String, TextEditingController> _subjectControllers = {};
  List<String> _subjectOrder = [];
  List<String> _exceptionList = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _periodsPerDayController.dispose();
    _periodLengthController.dispose();
    _teachingDaysController.dispose();
    _maxDailyLoadController.dispose();
    _newSubjectController.dispose();
    _newExceptionController.dispose();
    for (final c in _subjectControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final saved = await _service.getConfig(widget.project.id);
    final classSubjects = await _service.distinctSubjectsAcrossClasses(widget.project.id);
    final config = saved ?? TimetableConfig.empty();

    _periodsPerDayController.text = config.periodsPerDay.toString();
    _periodLengthController.text = config.periodLengthMinutes.toString();
    _teachingDaysController.text = config.teachingDaysPerWeek.toString();
    _maxDailyLoadController.text = config.maxDailyPeriodsPerTeacher.toString();
    _exceptionList = List.of(config.practicalSubjectsExceptionList);

    final allSubjects = {...classSubjects, ...config.subjectDefaults.keys}.toList()..sort();
    for (final s in allSubjects) {
      _subjectControllers[s] = TextEditingController(text: (config.subjectDefaults[s] ?? 5).toString());
    }
    _subjectOrder = allSubjects;

    if (!mounted) return;
    setState(() => _loading = false);
  }

  void _addSubject() {
    final name = _newSubjectController.text.trim();
    if (name.isEmpty || _subjectControllers.containsKey(name)) return;
    setState(() {
      _subjectControllers[name] = TextEditingController(text: '5');
      _subjectOrder = [..._subjectOrder, name]..sort();
      _newSubjectController.clear();
    });
  }

  void _removeSubject(String name) {
    setState(() {
      _subjectControllers.remove(name)?.dispose();
      _subjectOrder.remove(name);
    });
  }

  void _addException() {
    final name = _newExceptionController.text.trim();
    if (name.isEmpty || _exceptionList.contains(name)) return;
    setState(() {
      _exceptionList = [..._exceptionList, name];
      _newExceptionController.clear();
    });
  }

  Future<void> _save() async {
    final periodsPerDay = int.tryParse(_periodsPerDayController.text.trim());
    final periodLength = int.tryParse(_periodLengthController.text.trim());
    final teachingDays = int.tryParse(_teachingDaysController.text.trim());
    final maxDailyLoad = int.tryParse(_maxDailyLoadController.text.trim());
    if (periodsPerDay == null || periodLength == null || teachingDays == null || maxDailyLoad == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Periods/day, period length, teaching days, and max daily load must be numbers.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final subjectDefaults = <String, int>{
        for (final entry in _subjectControllers.entries) entry.key: int.tryParse(entry.value.text.trim()) ?? 5,
      };
      await _service.saveConfig(
        projectId: widget.project.id,
        config: TimetableConfig(
          periodsPerDay: periodsPerDay,
          periodLengthMinutes: periodLength,
          teachingDaysPerWeek: teachingDays,
          subjectDefaults: subjectDefaults,
          practicalSubjectsExceptionList: _exceptionList,
          maxDailyPeriodsPerTeacher: maxDailyLoad,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Timetable setup saved.')));
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _generate() async {
    await _save();
    if (!mounted) return;
    setState(() => _generating = true);
    try {
      final result = await _service.generate(widget.project.id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => IndependentTimetableGeneratedScreen(project: widget.project)),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Generated ${result.assignmentCount} lessons, ${result.conflictCount} conflict${result.conflictCount == 1 ? '' : 's'}.')),
      );
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Timetable Setup'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _saving
                ? const Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4)))
                : TextButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Day structure', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: TextField(controller: _periodsPerDayController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Periods per day', border: OutlineInputBorder()))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: _periodLengthController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Period length (min)', border: OutlineInputBorder()))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: _teachingDaysController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Teaching days/week', border: OutlineInputBorder()))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: _maxDailyLoadController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Max daily load/teacher', border: OutlineInputBorder()))),
                  ],
                ),
                const SizedBox(height: 24),
                Text('Subject periods per week', style: Theme.of(context).textTheme.titleMedium),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('Suggested default — adjust as needed.', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                ),
                for (final subject in _subjectOrder)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(child: Text(subject)),
                        SizedBox(
                          width: 70,
                          child: TextField(
                            controller: _subjectControllers[subject],
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _removeSubject(subject)),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newSubjectController,
                        decoration: const InputDecoration(labelText: 'Add subject', isDense: true, border: OutlineInputBorder()),
                        onSubmitted: (_) => _addSubject(),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.add), onPressed: _addSubject),
                  ],
                ),
                const SizedBox(height: 24),
                Text('Practical Subjects Exception List', style: Theme.of(context).textTheme.titleMedium),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('Subjects here may be scheduled as single periods. Everything else defaults to a continuous 2-period block.', style: TextStyle(fontSize: 12)),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final subject in _exceptionList)
                      Chip(label: Text(subject), onDeleted: () => setState(() => _exceptionList.remove(subject))),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newExceptionController,
                        decoration: const InputDecoration(labelText: 'Add practical subject', isDense: true, border: OutlineInputBorder()),
                        onSubmitted: (_) => _addException(),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.add), onPressed: _addException),
                  ],
                ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 16),
                Text('Automatic generation', style: Theme.of(context).textTheme.titleMedium),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'Runs the same deterministic engine (no AI) School Network\'s real Timetable Generation uses — no '
                    'double-booking, ever; anything it can\'t resolve is listed as a specific conflict.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: _generating
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4))
                      : const Icon(Icons.auto_awesome_outlined),
                  label: Text(_generating ? 'Generating...' : 'Save & Run Automatic Generator'),
                  onPressed: _generating ? null : _generate,
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
