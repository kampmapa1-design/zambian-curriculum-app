import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/report_class.dart';
import '../services/report_class_repository.dart';
import '../services/report_comment_engine.dart';

/// Report Form Pipeline, Stage 6 — "Omitted Entry": one learner missed
/// during bulk upload, entered manually from scratch (name + every
/// subject's score), feeding into the same Broad Mark Sheet and eligible
/// for report form creation exactly like any other learner. A composite
/// subject (e.g. Science) is shown read-only, computed live from the two
/// real scores entered here.
class OmittedEntryScreen extends StatefulWidget {
  const OmittedEntryScreen({super.key, required this.reportClass, this.repository});

  final ReportClass reportClass;
  final ReportClassRepository? repository;

  @override
  State<OmittedEntryScreen> createState() => _OmittedEntryScreenState();
}

class _OmittedEntryScreenState extends State<OmittedEntryScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  final _nameController = TextEditingController();
  List<ReportSubject> _subjects = const [];
  final Map<int, TextEditingController> _scoreControllers = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final c in _scoreControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final subjects = await _repository.listSubjects(widget.reportClass.id);
    for (final subject in subjects) {
      if (!subject.isComposite) _scoreControllers[subject.id] = TextEditingController();
    }
    if (!mounted) return;
    setState(() {
      _subjects = subjects;
      _loading = false;
    });
  }

  double? _plainScore(int subjectId) => double.tryParse(_scoreControllers[subjectId]?.text.trim() ?? '');

  double? _compositePreview(ReportSubject subject) {
    final a = _plainScore(subject.compositePartAId ?? -1);
    final b = _plainScore(subject.compositePartBId ?? -1);
    if (a == null || b == null) return null;
    return a + b;
  }

  bool get _canSave => _nameController.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      final learner = await _repository.addLearner(widget.reportClass.id, _nameController.text);
      for (final subject in _subjects) {
        if (subject.isComposite) continue;
        final scoreText = _scoreControllers[subject.id]!.text.trim();
        if (scoreText.isEmpty) continue;
        final score = double.tryParse(scoreText);
        if (score == null) continue;
        await _repository.setScore(
          learnerId: learner.id,
          subject: subject,
          score: score,
          comment: reportCommentFor(score),
          commentSource: ReportCommentSource.auto,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Omitted Entry')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                const Text('A learner missed during bulk upload — enter their name and every subject score '
                    'here, once, and they\'ll appear on the Broad Mark Sheet like everyone else.'),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                for (final subject in _subjects) _buildSubjectField(subject),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _canSave && !_saving ? _save : null,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.person_add_alt_1),
            label: Text(_saving ? 'Saving…' : 'Add Learner'),
          ),
        ),
      ),
    );
  }

  Widget _buildSubjectField(ReportSubject subject) {
    if (subject.isComposite) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const Icon(Icons.calculate_outlined),
          title: Text(subject.name),
          subtitle: const Text('Composite — computed automatically'),
          trailing: Text(_compositePreview(subject)?.toStringAsFixed(0) ?? '—'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _scoreControllers[subject.id],
        decoration: InputDecoration(labelText: '${subject.name} score', border: const OutlineInputBorder()),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}
