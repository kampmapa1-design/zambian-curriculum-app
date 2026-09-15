import 'package:flutter/material.dart';

import '../models/school.dart';
import '../models/timetable.dart';
import '../services/school_class_link_service.dart';
import '../services/school_service.dart';
import '../services/timetable_service.dart';

/// Timetable Generation, Stage 3 — natural-language constraint entry.
/// Per the brief: "showing the operator the parsed result for
/// confirmation before it's applied — never applying an AI
/// interpretation silently." This screen is a strict two-step flow:
/// type an instruction and press Interpret, review exactly what was
/// understood (including the real teacher/class it matched, or that it
/// matched nothing), then press Apply only if it's right. Nothing is
/// written to the school's data until that second, explicit tap.
class TimetableConstraintsScreen extends StatefulWidget {
  const TimetableConstraintsScreen({required this.school, super.key});
  final School school;

  @override
  State<TimetableConstraintsScreen> createState() => _TimetableConstraintsScreenState();
}

class _TimetableConstraintsScreenState extends State<TimetableConstraintsScreen> {
  final _timetableService = TimetableService();
  final _linkService = SchoolClassLinkService();
  final _textController = TextEditingController();

  bool _interpreting = false;
  bool _applying = false;
  ParsedTimetableConstraint? _parsed;
  String? _error;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _interpret() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _interpreting = true;
      _error = null;
      _parsed = null;
    });
    try {
      final parsed = await _timetableService.parseConstraint(schoolId: widget.school.id, text: text);
      if (!mounted) return;
      setState(() => _parsed = parsed);
    } on SchoolException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _interpreting = false);
    }
  }

  Future<void> _apply() async {
    final parsed = _parsed;
    if (parsed == null) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      if (parsed.kind == 'availability' && parsed.teacherUid != null) {
        await _timetableService.setTeacherAvailability(
          schoolId: widget.school.id,
          teacherUid: parsed.teacherUid!,
          unavailableSlots: parsed.unavailableSlots,
        );
      } else if (parsed.kind == 'assignment' && parsed.teacherUid != null && parsed.classId != null && parsed.subjectName.isNotEmpty) {
        await _linkService.assignSubjectTeacher(
          schoolId: widget.school.id,
          classId: parsed.classId!,
          subjectName: parsed.subjectName,
          targetUid: parsed.teacherUid,
        );
      } else {
        setState(() => _error = "This couldn't be matched to a real teacher/class — nothing was applied. Try rephrasing, or use Staff & Roles / Timetable Setup directly.");
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Applied.')));
      setState(() {
        _parsed = null;
        _textController.clear();
      });
    } on SchoolException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Timetable Constraints')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Describe a teacher\'s availability or a subject-teacher assignment in plain language, e.g. '
            '"Mr. Phiri is unavailable on Friday afternoons" or "Mrs. Banda can only teach mornings". '
            'Nothing is applied until you review and confirm it below.',
            style: TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _textController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Instruction', border: OutlineInputBorder(), alignLabelWithHint: true),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: _interpreting
                ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Icon(Icons.auto_awesome_outlined),
            label: Text(_interpreting ? 'Interpreting...' : 'Interpret'),
            onPressed: _interpreting ? null : _interpret,
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_parsed != null) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            Text('Understood as:', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_parsed!.summary),
                    const SizedBox(height: 8),
                    _matchLine('Teacher', _parsed!.teacherName, _parsed!.teacherUid != null),
                    if (_parsed!.kind == 'assignment') ...[
                      _matchLine('Class', _parsed!.className, _parsed!.classId != null),
                      _matchLine('Subject', _parsed!.subjectName, _parsed!.subjectName.isNotEmpty),
                    ],
                    if (_parsed!.kind == 'unrecognized')
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text("Couldn't tell whether this was an availability or assignment instruction.", style: TextStyle(fontStyle: FontStyle.italic)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: _applying
                  ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : const Icon(Icons.check_circle_outline),
              label: Text(_applying ? 'Applying...' : 'Apply'),
              onPressed: _applying || _parsed!.kind == 'unrecognized' ? null : _apply,
            ),
          ],
        ],
      ),
    );
  }

  Widget _matchLine(String label, String value, bool matched) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(matched ? Icons.check_circle : Icons.error_outline, size: 16, color: matched ? Colors.green : Colors.orange),
          const SizedBox(width: 6),
          Text('$label: $value', style: const TextStyle(fontSize: 13)),
          if (!matched) const Text('  (no confident match — won\'t be applied)', style: TextStyle(fontSize: 11, color: Colors.orange)),
        ],
      ),
    );
  }
}
