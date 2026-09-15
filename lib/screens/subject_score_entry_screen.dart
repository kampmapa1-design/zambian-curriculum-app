import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_score_entry_service.dart';
import '../services/school_service.dart';
import '../services/scan_marker_flag_service.dart';

/// Stage 4 (writing scores) + Stage 5 (the flagged-entry check) of School
/// Network, together since Stage 5 gates entry into this exact screen.
class SubjectScoreEntryScreen extends StatefulWidget {
  const SubjectScoreEntryScreen({
    required this.schoolId,
    required this.schoolClass,
    required this.subjectName,
    super.key,
  });

  final String schoolId;
  final SchoolClass schoolClass;
  final String subjectName;

  @override
  State<SubjectScoreEntryScreen> createState() => _SubjectScoreEntryScreenState();
}

class _SubjectScoreEntryScreenState extends State<SubjectScoreEntryScreen> {
  final _scoreEntryService = SchoolScoreEntryService();
  final _flagService = ScanMarkerFlagService();
  bool _checkingFlags = true;
  bool _blockedByFlags = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runFlagCheck());
  }

  Future<void> _runFlagCheck() async {
    final hasFlags = await _flagService.hasUnresolvedFlags(
      classLevel: widget.schoolClass.classGrade,
      subjectName: widget.subjectName,
    );
    if (!mounted) return;
    if (!hasFlags) {
      setState(() => _checkingFlags = false);
      return;
    }
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Some entries still need review'),
        content: const Text(
          'There are some entries that still need to be edited, do you still want to proceed anyway?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Finish Editing')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Update Report Form As-Is')),
        ],
      ),
    );
    if (!mounted) return;
    if (proceed == true) {
      setState(() => _checkingFlags = false);
    } else {
      setState(() => _blockedByFlags = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.subjectName} — ${widget.schoolClass.label}')),
      body: _checkingFlags
          ? const Center(child: CircularProgressIndicator())
          : _blockedByFlags
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Go back to Scan Marker to finish reviewing the flagged scripts for this class/subject, then come back here.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back')),
                      ],
                    ),
                  ),
                )
              : StreamBuilder<List<ScoreEntry>>(
                  stream: _scoreEntryService.watchEntries(widget.schoolId, widget.schoolClass.id),
                  builder: (context, snapshot) {
                    final entries = snapshot.data ?? const [];
                    final byIndex = {for (final e in entries) if (e.subjectName == widget.subjectName) e.learnerIndex: e};
                    return ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: widget.schoolClass.learnerNames.length,
                      separatorBuilder: (_, __) => const Divider(),
                      itemBuilder: (context, index) {
                        final learnerName = widget.schoolClass.learnerNames[index];
                        return _LearnerScoreRow(
                          learnerName: learnerName,
                          existing: byIndex[index],
                          onSave: (score, comment) => _saveScore(index, score, comment),
                        );
                      },
                    );
                  },
                ),
    );
  }

  Future<void> _saveScore(int learnerIndex, double score, String comment) async {
    try {
      await _scoreEntryService.submitScore(
        schoolId: widget.schoolId,
        classId: widget.schoolClass.id,
        learnerIndex: learnerIndex,
        subjectName: widget.subjectName,
        score: score,
        comment: comment,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved.')));
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _LearnerScoreRow extends StatefulWidget {
  const _LearnerScoreRow({required this.learnerName, required this.existing, required this.onSave});
  final String learnerName;
  final ScoreEntry? existing;
  final Future<void> Function(double score, String comment) onSave;

  @override
  State<_LearnerScoreRow> createState() => _LearnerScoreRowState();
}

class _LearnerScoreRowState extends State<_LearnerScoreRow> {
  late final _scoreController = TextEditingController(text: widget.existing?.score.toStringAsFixed(0) ?? '');
  late final _commentController = TextEditingController(text: widget.existing?.comment ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _scoreController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final score = double.tryParse(_scoreController.text.trim());
    if (score == null) return;
    setState(() => _saving = true);
    await widget.onSave(score, _commentController.text.trim());
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.learnerName, style: Theme.of(context).textTheme.titleSmall),
          if (existing != null && existing.editHistory.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                'Last edited by ${existing.lastEditedByName} (originally entered by ${existing.submittedByName})',
                style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.tertiary),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _scoreController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Score', isDense: true, border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _commentController,
                  decoration: const InputDecoration(labelText: 'Comment (optional)', isDense: true, border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 8),
              _saving
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : IconButton(icon: const Icon(Icons.check_circle_outline), onPressed: _save),
            ],
          ),
        ],
      ),
    );
  }
}
