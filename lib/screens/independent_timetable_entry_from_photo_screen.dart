import 'dart:io';

import 'package:flutter/material.dart';

import '../models/independent_timetable_project.dart';
import '../models/timetable.dart';
import '../services/independent_timetable_service.dart';
import '../services/school_service.dart' show SchoolException;
import 'document_pages_capture_screen.dart';

enum _Step { capturing, reading, review, error }

/// "Build Timetable for Another School" (added 2026-09-16) — AI-assisted
/// setup from a photographed paper timetable, for ONE class in an
/// independent project. Mirrors [TimetableEntryFromPhotoScreen]'s
/// review-before-save discipline exactly; the one real difference is the
/// teacher field — there's no real member roster to pick from here, so
/// each row gets a plain editable text field (pre-filled with whatever
/// name the AI read, or the exact match already typed into this class if
/// one was found) instead of a dropdown.
class IndependentTimetableEntryFromPhotoScreen extends StatefulWidget {
  const IndependentTimetableEntryFromPhotoScreen({required this.project, required this.schoolClass, super.key});
  final IndependentTimetableProject project;
  final IndependentTimetableClass schoolClass;

  @override
  State<IndependentTimetableEntryFromPhotoScreen> createState() => _IndependentTimetableEntryFromPhotoScreenState();
}

class _IndependentTimetableEntryFromPhotoScreenState extends State<IndependentTimetableEntryFromPhotoScreen> {
  final _service = IndependentTimetableService();

  _Step _step = _Step.capturing;
  String? _errorMessage;
  ExtractedTimetable? _extracted;
  bool _saving = false;

  late final _periodsPerDayController = TextEditingController();
  late final _periodLengthController = TextEditingController();
  late final _teachingDaysController = TextEditingController();
  final Map<int, TextEditingController> _periodsPerWeekControllers = {};
  final Map<int, TextEditingController> _teacherNameControllers = {};
  final Map<int, bool> _includeSubject = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  @override
  void dispose() {
    _periodsPerDayController.dispose();
    _periodLengthController.dispose();
    _teachingDaysController.dispose();
    for (final c in _periodsPerWeekControllers.values) {
      c.dispose();
    }
    for (final c in _teacherNameControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _capture() async {
    setState(() => _step = _Step.capturing);
    final pages = await Navigator.of(context).push<List<File>>(
      MaterialPageRoute(
        builder: (_) => const DocumentPagesCaptureScreen(
          title: 'Capture Paper Timetable',
          instructions: "Photograph this class's existing timetable — every value read from it will be shown for you to review before anything is saved.",
        ),
      ),
    );
    if (!mounted) return;
    if (pages == null || pages.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    await _read(pages);
  }

  Future<void> _read(List<File> pages) async {
    setState(() {
      _step = _Step.reading;
      _errorMessage = null;
    });
    try {
      final extracted = await _service.extractFromPhotos(projectId: widget.project.id, pageFiles: pages);
      if (!mounted) return;
      _periodsPerDayController.text = extracted.periodsPerDay > 0 ? extracted.periodsPerDay.toString() : '8';
      _periodLengthController.text = extracted.periodLengthMinutes > 0 ? extracted.periodLengthMinutes.toString() : '40';
      _teachingDaysController.text = extracted.teachingDaysPerWeek > 0 ? extracted.teachingDaysPerWeek.toString() : '5';
      for (var i = 0; i < extracted.subjects.length; i++) {
        final s = extracted.subjects[i];
        _periodsPerWeekControllers[i] = TextEditingController(text: s.periodsPerWeek > 0 ? s.periodsPerWeek.toString() : '5');
        _teacherNameControllers[i] = TextEditingController(text: s.teacherUid ?? s.teacherName);
        _includeSubject[i] = true;
      }
      setState(() {
        _extracted = extracted;
        _step = _Step.review;
      });
    } on SchoolException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _step = _Step.error;
      });
    }
  }

  Future<void> _confirm() async {
    final extracted = _extracted;
    if (extracted == null) return;
    final periodsPerDay = int.tryParse(_periodsPerDayController.text.trim());
    final periodLength = int.tryParse(_periodLengthController.text.trim());
    final teachingDays = int.tryParse(_teachingDaysController.text.trim());
    if (periodsPerDay == null || periodLength == null || teachingDays == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Periods/day, period length, and teaching days must be numbers.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final existingConfig = await _service.getConfig(widget.project.id);
      final subjectDefaults = <String, int>{...(existingConfig?.subjectDefaults ?? {})};
      for (var i = 0; i < extracted.subjects.length; i++) {
        if (_includeSubject[i] != true) continue;
        final periodsPerWeek = int.tryParse(_periodsPerWeekControllers[i]?.text.trim() ?? '') ?? 5;
        subjectDefaults[extracted.subjects[i].name] = periodsPerWeek;
      }
      await _service.saveConfig(
        projectId: widget.project.id,
        config: TimetableConfig(
          periodsPerDay: periodsPerDay,
          periodLengthMinutes: periodLength,
          teachingDaysPerWeek: teachingDays,
          subjectDefaults: subjectDefaults,
          practicalSubjectsExceptionList: existingConfig?.practicalSubjectsExceptionList ?? const [],
          maxDailyPeriodsPerTeacher: existingConfig?.maxDailyPeriodsPerTeacher ?? 6,
        ),
      );

      var assigned = 0;
      var skipped = 0;
      for (var i = 0; i < extracted.subjects.length; i++) {
        if (_includeSubject[i] != true) continue;
        final teacherName = _teacherNameControllers[i]?.text.trim() ?? '';
        if (teacherName.isEmpty) {
          skipped++;
          continue;
        }
        await _service.assignSubjectTeacher(projectId: widget.project.id, classId: widget.schoolClass.id, subjectName: extracted.subjects[i].name, teacherName: teacherName);
        assigned++;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Timetable setup saved. $assigned subject teacher${assigned == 1 ? '' : 's'} assigned${skipped > 0 ? ', $skipped left blank — fill in Classes & Subjects.' : '.'}')),
      );
      Navigator.of(context).pop();
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Timetable from Photo')),
      body: switch (_step) {
        _Step.capturing => const Center(child: CircularProgressIndicator()),
        _Step.reading => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 16), Text('Reading the timetable with AI…')]),
            ),
          ),
        _Step.error => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_errorMessage ?? 'Something went wrong.', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _capture, child: const Text('Try again')),
                ],
              ),
            ),
          ),
        _Step.review => _buildReview(context),
      },
    );
  }

  Widget _buildReview(BuildContext context) {
    final extracted = _extracted!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (extracted.notes.isNotEmpty) ...[
          Card(
            color: Colors.amber.shade50,
            child: Padding(padding: const EdgeInsets.all(12), child: Text('AI note: ${extracted.notes}', style: const TextStyle(fontSize: 12.5))),
          ),
          const SizedBox(height: 16),
        ],
        Text('Day structure', style: Theme.of(context).textTheme.titleMedium),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text('Read from the photo — this applies to the whole project, adjust if anything looks off.', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
        ),
        Row(
          children: [
            Expanded(child: TextField(controller: _periodsPerDayController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Periods/day', border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _periodLengthController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Period length (min)', border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _teachingDaysController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Teaching days/wk', border: OutlineInputBorder()))),
          ],
        ),
        const SizedBox(height: 24),
        Text('Subjects for ${widget.schoolClass.classGrade}', style: Theme.of(context).textTheme.titleMedium),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text('Uncheck anything that was misread. Fix the teacher name for any row that looks wrong.', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
        ),
        for (var i = 0; i < extracted.subjects.length; i++) _subjectRow(context, i, extracted.subjects[i]),
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Icon(Icons.check_circle_outline),
          label: Text(_saving ? 'Saving...' : 'Confirm & Save'),
          onPressed: _saving ? null : _confirm,
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _subjectRow(BuildContext context, int index, ExtractedTimetableSubject subject) {
    final included = _includeSubject[index] ?? true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(value: included, onChanged: (v) => setState(() => _includeSubject[index] = v ?? true)),
                Expanded(child: Text(subject.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                SizedBox(
                  width: 60,
                  child: TextField(
                    controller: _periodsPerWeekControllers[index],
                    enabled: included,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true, labelText: 'per wk', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            if (included)
              Padding(
                padding: const EdgeInsets.only(left: 44, top: 4),
                child: TextField(
                  controller: _teacherNameControllers[index],
                  decoration: const InputDecoration(isDense: true, labelText: 'Teacher name', border: OutlineInputBorder()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
