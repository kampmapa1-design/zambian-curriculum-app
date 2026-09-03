import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/report_class.dart';
import '../services/report_class_backup_service.dart';
import '../services/report_class_repository.dart';
import '../services/report_comment_engine.dart';

/// Report Form Pipeline, Stage 7 — "Update Learner Data": one learner's
/// name and every (non-composite) subject's score/comment, editable in one
/// place, without touching any other learner's row. Reached only via
/// [BroadMarkSheetScreen]'s own Edit choice (long-press a row). A composite
/// subject (e.g. Science) is shown read-only — its value is always the sum
/// of its two real parts, entered here like any other subject.
///
/// For a Continuous Assessment class, each subject shows its real Test and
/// Exam fields (see [ReportClassRepository.setComponentScore]) instead of
/// one Score field — the final score is always computed, never typed here.
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
  late final TextEditingController _guardianEmailController;
  late final TextEditingController _guardianPhoneController;
  List<ReportSubject> _subjects = const [];
  final Map<int, TextEditingController> _scoreControllers = {};
  final Map<int, TextEditingController> _caTestControllers = {};
  final Map<int, TextEditingController> _caExamControllers = {};
  final Map<int, TextEditingController> _commentControllers = {};

  // Loaded-value snapshots, so Save only ever writes (and only ever
  // re-stamps a post-completion edit — see ReportScore.editedAfterCompletionAt)
  // fields that actually changed, rather than every field on every save.
  final Map<int, String> _originalScoreText = {};
  final Map<int, String> _originalCaTestText = {};
  final Map<int, String> _originalCaExamText = {};
  final Map<int, String> _originalCommentText = {};

  Map<int, double?> _compositeValues = {};
  bool _loading = true;
  bool _saving = false;

  bool get _isCa => widget.reportClass.isContinuousAssessment;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.learner.fullName);
    _guardianEmailController = TextEditingController(text: widget.learner.guardianEmail ?? '');
    _guardianPhoneController = TextEditingController(text: widget.learner.guardianPhone ?? '');
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _guardianEmailController.dispose();
    _guardianPhoneController.dispose();
    for (final c in _scoreControllers.values) {
      c.dispose();
    }
    for (final c in _caTestControllers.values) {
      c.dispose();
    }
    for (final c in _caExamControllers.values) {
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
      if (_isCa) {
        final testText = score?.caTestScore?.toStringAsFixed(0) ?? '';
        final examText = score?.caExamScore?.toStringAsFixed(0) ?? '';
        _caTestControllers[subject.id] = TextEditingController(text: testText);
        _caExamControllers[subject.id] = TextEditingController(text: examText);
        _originalCaTestText[subject.id] = testText;
        _originalCaExamText[subject.id] = examText;
      } else {
        final scoreText = score?.score?.toStringAsFixed(0) ?? '';
        _scoreControllers[subject.id] = TextEditingController(text: scoreText);
        _originalScoreText[subject.id] = scoreText;
      }
      final commentText = score?.comment ?? '';
      _commentControllers[subject.id] = TextEditingController(text: commentText);
      _originalCommentText[subject.id] = commentText;
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
      await _repository.updateGuardianContact(
        widget.learner.id,
        email: _guardianEmailController.text,
        phone: _guardianPhoneController.text,
      );
      for (final subject in _subjects) {
        if (subject.isComposite) continue;
        final commentText = _commentControllers[subject.id]!.text.trim();
        final commentChanged = commentText != (_originalCommentText[subject.id] ?? '');

        if (_isCa) {
          final testText = _caTestControllers[subject.id]!.text.trim();
          final examText = _caExamControllers[subject.id]!.text.trim();
          if (testText.isNotEmpty && testText != (_originalCaTestText[subject.id] ?? '')) {
            final value = double.tryParse(testText);
            if (value != null) {
              await _repository.setComponentScore(
                learnerId: widget.learner.id,
                subject: subject,
                reportClass: widget.reportClass,
                component: ReportCaComponent.test,
                value: value,
              );
            }
          }
          if (examText.isNotEmpty && examText != (_originalCaExamText[subject.id] ?? '')) {
            final value = double.tryParse(examText);
            if (value != null) {
              await _repository.setComponentScore(
                learnerId: widget.learner.id,
                subject: subject,
                reportClass: widget.reportClass,
                component: ReportCaComponent.exam,
                value: value,
              );
            }
          }
          if (commentChanged) {
            await _repository.setComment(
              learnerId: widget.learner.id,
              subject: subject,
              comment: commentText.isEmpty ? null : commentText,
              commentSource: ReportCommentSource.manual,
            );
          }
        } else {
          final scoreText = _scoreControllers[subject.id]!.text.trim();
          final scoreChanged = scoreText != (_originalScoreText[subject.id] ?? '');
          if (scoreChanged || commentChanged) {
            final score = scoreText.isEmpty ? null : double.tryParse(scoreText);
            await _repository.setScore(
              learnerId: widget.learner.id,
              subject: subject,
              score: score,
              comment: commentText.isEmpty ? null : commentText,
              commentSource: ReportCommentSource.manual,
            );
          }
        }
      }
      unawaited(ReportClassBackupService().maybeBackup(widget.reportClass.id, repository: _repository));
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $error')));
      setState(() => _saving = false);
    }
  }

  void _autoFillComment(ReportSubject subject) {
    final score = _isCa
        ? _computedCaPreview(subject)
        : double.tryParse(_scoreControllers[subject.id]!.text.trim());
    if (score == null) return;
    setState(() => _commentControllers[subject.id]!.text = reportCommentFor(score));
  }

  double? _computedCaPreview(ReportSubject subject) {
    final test = double.tryParse(_caTestControllers[subject.id]?.text.trim() ?? '');
    final exam = double.tryParse(_caExamControllers[subject.id]?.text.trim() ?? '');
    if (test == null || exam == null || !widget.reportClass.hasConfirmedCaWeights) return null;
    return test * widget.reportClass.caTestWeightPercent! / 100 + exam * widget.reportClass.caExamWeightPercent! / 100;
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
                const SizedBox(height: 12),
                TextField(
                  controller: _guardianEmailController,
                  decoration: const InputDecoration(
                    labelText: 'Guardian email (optional)',
                    helperText: 'Where this learner\'s report form will be sent',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _guardianPhoneController,
                  decoration: const InputDecoration(
                    labelText: 'Guardian phone (optional)',
                    helperText: 'For WhatsApp / SMS — include the country code',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.phone,
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
            if (_isCa) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _caTestControllers[subject.id],
                      decoration: const InputDecoration(labelText: 'C.A. Test', isDense: true, border: OutlineInputBorder()),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _caExamControllers[subject.id],
                      decoration: const InputDecoration(labelText: 'Exam', isDense: true, border: OutlineInputBorder()),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                widget.reportClass.hasConfirmedCaWeights
                    ? 'Final (computed): ${_computedCaPreview(subject)?.toStringAsFixed(1) ?? '—'}'
                    : 'C.A. weighting not yet confirmed — final score will compute once it is.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => _autoFillComment(subject), child: const Text('Auto-fill comment')),
              ),
            ] else
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
