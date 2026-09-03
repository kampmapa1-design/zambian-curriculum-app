import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';
import '../services/report_comment_engine.dart';

/// Report Form Pipeline, Stage 7 — "Update Learner Data": one learner's
/// name and every (non-composite) subject's score/comment, editable in one
/// place, without touching any other learner's row. Reached only via
/// [BroadMarkSheetScreen]'s own "Edit?" confirmation (long-press a row).
/// A composite subject (e.g. Science) is shown read-only — its value is
/// always the sum of its two real parts, entered here like any other
/// subject.
class LearnerEditScreen extends StatefulWidget {
  const LearnerEditScreen({super.key, required this.reportClass, required this.learner, this.repository});

  final ReportClass reportClass;
  final ReportLearner learner;
  final ReportClassRepository? repository;

  @override
  State<LearnerEditScreen> createState() => _LearnerEditScreenState();
}

class _LearnerEditScreenState extends State<LearnerEditScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  late final TextEditingController _nameController;
  List<ReportSubject> _subjects = const [];
  final Map<int, TextEditingController> _scoreControllers = {};
  final Map<int, TextEditingController> _commentControllers = {};
  Map<int, double?> _compositeValues = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.learner.fullName);
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final c in _scoreControllers.values) {
      c.dispose();
    }
    for (final c in _commentControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final subjects = await _repository.listSubjects(widget.reportClass.id);
    final composites = <int, double?>{};
    for (final subject in subjects) {
      if (subject.isComposite) {
        composites[subject.id] = await _repository.scoreFor(widget.learner.id, subject, allSubjects: subjects);
        continue;
      }
      final score = await _repository.getScore(widget.learner.id, subject.id);
      _scoreControllers[subject.id] = TextEditingController(text: score?.score?.toStringAsFixed(0) ?? '');
      _commentControllers[subject.id] = TextEditingController(text: score?.comment ?? '');
    }
    if (!mounted) return;
    setState(() {
      _subjects = subjects;
      _compositeValues = composites;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      if (_nameController.text.trim() != widget.learner.fullName) {
        await _repository.renameLearner(widget.learner.id, _nameController.text);
      }
      for (final subject in _subjects) {
        if (subject.isComposite) continue;
        final scoreText = _scoreControllers[subject.id]!.text.trim();
        final score = scoreText.isEmpty ? null : double.tryParse(scoreText);
        await _repository.setScore(
          learnerId: widget.learner.id,
          subject: subject,
          score: score,
          comment: _commentControllers[subject.id]!.text.trim().isEmpty ? null : _commentControllers[subject.id]!.text.trim(),
          commentSource: ReportCommentSource.manual,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $error')));
      setState(() => _saving = false);
    }
  }

  void _autoFillComment(ReportSubject subject) {
    final score = double.tryParse(_scoreControllers[subject.id]!.text.trim());
    if (score == null) return;
    setState(() => _commentControllers[subject.id]!.text = reportCommentFor(score));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.learner.fullName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 16),
                for (final subject in _subjects) _buildSubjectCard(subject),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ),
      ),
    );
  }

  Widget _buildSubjectCard(ReportSubject subject) {
    if (subject.isComposite) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const Icon(Icons.calculate_outlined),
          title: Text(subject.name),
          subtitle: const Text('Composite — computed automatically from its two subjects'),
          trailing: Text(_compositeValues[subject.id]?.toStringAsFixed(0) ?? '—'),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subject.name, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _scoreControllers[subject.id],
                    decoration: const InputDecoration(labelText: 'Score', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(onPressed: () => _autoFillComment(subject), child: const Text('Auto-fill comment')),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _commentControllers[subject.id],
              decoration: const InputDecoration(labelText: 'Comment', isDense: true, border: OutlineInputBorder()),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }
}
