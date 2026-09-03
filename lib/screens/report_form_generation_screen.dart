import 'dart:async';

import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../services/report_class_backup_service.dart';
import '../services/report_class_repository.dart';
import '../services/report_comment_engine.dart';
import '../services/report_form_document_service.dart';
import '../services/generated_report_form_repository.dart';
import 'report_form_list_screen.dart';

/// Report Form Pipeline, Stage 10 (mail-merge generation) + Stage 11
/// (subject teacher comment override). Stage 11 first: for every subject
/// on this class, ask whether to auto-fill that subject's comments from
/// Stage 8's deterministic score-band engine — checked subjects get every
/// learner's comment replaced with the matching band text; unchecked
/// subjects keep whatever's already stored (blank if nothing was ever
/// entered), left for manual entry. Then Stage 10: one report generated
/// per roster learner by default, with class position computed from the
/// whole roster's aggregate scores.
class ReportFormGenerationScreen extends StatefulWidget {
  const ReportFormGenerationScreen({
    super.key,
    required this.reportClass,
    this.repository,
    this.reportFormRepository,
    this.documentService,
  });

  final ReportClass reportClass;
  final ReportClassRepository? repository;
  final GeneratedReportFormRepository? reportFormRepository;
  final ReportFormDocumentService? documentService;

  @override
  State<ReportFormGenerationScreen> createState() => _ReportFormGenerationScreenState();
}

class _ReportFormGenerationScreenState extends State<ReportFormGenerationScreen> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  late final GeneratedReportFormRepository _reportFormRepository =
      widget.reportFormRepository ?? GeneratedReportFormRepository();
  late final ReportFormDocumentService _documentService = widget.documentService ?? ReportFormDocumentService();

  List<ReportSubject> _subjects = const [];
  List<ReportLearner> _learners = const [];
  final Set<int> _autoFillSubjectIds = {};
  bool _loading = true;
  bool _generating = false;
  String _progressText = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final subjects = await _repository.listSubjects(widget.reportClass.id);
    final learners = await _repository.listLearners(widget.reportClass.id);
    if (!mounted) return;
    setState(() {
      _subjects = subjects;
      _learners = learners;
      _loading = false;
    });
  }

  Future<void> _generate() async {
    if (_learners.isEmpty || _subjects.isEmpty) return;
    setState(() {
      _generating = true;
      _progressText = 'Computing class positions…';
    });

    final positions = await _repository.classPositions(widget.reportClass.id);
    final classSize = (await _repository.aggregateScores(widget.reportClass.id))
        .values
        .where((v) => v != null)
        .length;

    var done = 0;
    for (final learner in _learners) {
      if (!mounted) return;
      setState(() => _progressText = 'Generating ${learner.fullName}\'s report (${done + 1} of ${_learners.length})…');

      final scores = <int, double?>{};
      final comments = <int, String?>{};
      final caTestScores = <int, double?>{};
      final caExamScores = <int, double?>{};
      for (final subject in _subjects) {
        final score = await _repository.scoreFor(learner.id, subject, allSubjects: _subjects);
        scores[subject.id] = score;

        ReportScore? existing;
        if (!subject.isComposite) {
          existing = await _repository.getScore(learner.id, subject.id);
          caTestScores[subject.id] = existing?.caTestScore;
          caExamScores[subject.id] = existing?.caExamScore;
        }

        if (_autoFillSubjectIds.contains(subject.id) && score != null) {
          comments[subject.id] = reportCommentFor(score);
          if (!subject.isComposite) {
            // A C.A. subject's `score` is always the computed weighted sum
            // (see setComponentScore) — writing through setComment instead
            // of setScore here means auto-fill only ever touches the
            // comment, never re-writes a score that isn't this screen's to
            // set directly.
            if (widget.reportClass.isContinuousAssessment) {
              await _repository.setComment(
                learnerId: learner.id,
                subject: subject,
                comment: comments[subject.id],
                commentSource: ReportCommentSource.auto,
              );
            } else {
              await _repository.setScore(
                learnerId: learner.id,
                subject: subject,
                score: score,
                comment: comments[subject.id],
                commentSource: ReportCommentSource.auto,
              );
            }
          }
        } else {
          comments[subject.id] = existing?.comment;
        }
      }

      final data = ReportFormMailMergeData(
        reportClass: widget.reportClass,
        learner: learner,
        subjects: _subjects,
        scores: scores,
        comments: comments,
        caTestScores: caTestScores,
        caExamScores: caExamScores,
        classPosition: positions[learner.id],
        classSize: classSize,
      );
      final docxBytes = _documentService.generateForLearner(data);
      await _reportFormRepository.saveReport(
        classId: widget.reportClass.id,
        learnerId: learner.id,
        learnerName: learner.fullName,
        docxBytes: docxBytes,
      );
      done++;
    }

    unawaited(ReportClassBackupService().maybeBackup(widget.reportClass.id, repository: _repository));

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ReportFormListScreen(
          reportClass: widget.reportClass,
          repository: _repository,
          reportFormRepository: _reportFormRepository,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Report Form')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _generating
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Padding(padding: const EdgeInsets.symmetric(horizontal: 32), child: Text(_progressText, textAlign: TextAlign.center)),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    Text(
                      'A report form will be generated for every one of the ${_learners.length} learner(s) on '
                      'this class\'s roster.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    Text('Auto-fill your comments based on scores?', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Check a subject to fill every learner\'s comment for it automatically — leave it '
                      'unchecked to keep whatever\'s already there (or blank) for manual entry.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    for (final subject in _subjects)
                      CheckboxListTile(
                        title: Text(subject.name),
                        value: _autoFillSubjectIds.contains(subject.id),
                        onChanged: (checked) => setState(() {
                          if (checked == true) {
                            _autoFillSubjectIds.add(subject.id);
                          } else {
                            _autoFillSubjectIds.remove(subject.id);
                          }
                        }),
                      ),
                  ],
                ),
      bottomNavigationBar: _loading || _generating
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _learners.isEmpty || _subjects.isEmpty ? null : _generate,
                  icon: const Icon(Icons.description_outlined),
                  label: Text('Create ${_learners.length} Report Form(s)'),
                ),
              ),
            ),
    );
  }
}
