import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/report_class.dart';
import '../services/handwritten_list_transcription_service.dart';
import '../services/report_class_repository.dart';
import '../services/report_comment_engine.dart';
import 'document_pages_capture_screen.dart';

/// Report Form Pipeline, Stages 2-4 in one flow (they're inseparable to
/// test meaningfully on their own — Stage 2's roster-matching only makes
/// sense once Stage 3 has actually extracted something, and Stage 4's
/// review is what commits Stage 2/3's work):
///
/// - **Stage 3, OCR ingestion**: reuses [HandwrittenListTranscriptionService]
///   (already deployed for "Capture Manual Scores") — a generic table
///   (headers + rows) extractor, not free transcription, exactly the
///   "structured tabular extraction, not free transcription" the brief
///   asked for. No new Cloud Function needed.
/// - **Stage 2, roster establishment/matching**: [ReportClassRepository
///   .matchNamesAgainstRoster] — the first upload for a class becomes the
///   roster; every later upload matches by exact normalized name, flagging
///   anything that doesn't match for the teacher to resolve below rather
///   than guessing.
/// - **Stage 4, validation before commit**: every row is shown editable,
///   next to the original captured image(s), and nothing is written to
///   [ReportClassRepository] until "Confirm & Save" — the primary error-
///   catching checkpoint in the whole pipeline, per the brief.
class UploadScoreSheetFlow extends StatefulWidget {
  const UploadScoreSheetFlow({
    super.key,
    required this.reportClass,
    this.repository,
    this.transcriptionService,
  });

  final ReportClass reportClass;
  final ReportClassRepository? repository;
  final HandwrittenListTranscriptionService? transcriptionService;

  @override
  State<UploadScoreSheetFlow> createState() => _UploadScoreSheetFlowState();
}

enum _Step { subject, capturing, transcribeError, review }

class _ScoreRowState {
  final name = TextEditingController();
  final score = TextEditingController();
  ReportLearner? matchedLearner;

  /// For an unmatched row only: true once the teacher has confirmed this
  /// is genuinely a new learner missed from the roster, rather than a
  /// misspelling/variant of someone already on it. Never defaulted true —
  /// see this flow's own doc comment on Stage 4.
  bool confirmedAsNew = false;

  _ScoreRowState({required String name, required String score, this.matchedLearner}) {
    this.name.text = name;
    this.score.text = score;
  }

  bool get isResolved => matchedLearner != null || confirmedAsNew;

  void dispose() {
    name.dispose();
    score.dispose();
  }
}

class _UploadScoreSheetFlowState extends State<UploadScoreSheetFlow> {
  late final ReportClassRepository _repository = widget.repository ?? ReportClassRepository();
  late final HandwrittenListTranscriptionService _transcriptionService =
      widget.transcriptionService ?? HandwrittenListTranscriptionService();

  _Step _step = _Step.subject;
  final _subjectController = TextEditingController();
  List<File> _capturedPages = const [];
  bool _transcribing = false;
  String _statusText = '';
  String? _lastError;
  String? _aiNotes;
  final List<_ScoreRowState> _rows = [];
  List<ReportLearner> _roster = const [];
  bool _saving = false;

  @override
  void dispose() {
    _subjectController.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseCaptureMethod() async {
    if (_subjectController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name this subject first (e.g. "Mathematics").')),
      );
      return;
    }
    final method = await showModalBottomSheet<_CaptureMethod>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Scan with Camera'),
              onTap: () => Navigator.of(sheetContext).pop(_CaptureMethod.camera),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Upload from Device'),
              onTap: () => Navigator.of(sheetContext).pop(_CaptureMethod.device),
            ),
          ],
        ),
      ),
    );
    if (method == null || !mounted) return;

    if (method == _CaptureMethod.camera) {
      setState(() => _step = _Step.capturing);
      final pages = await Navigator.of(context).push<List<File>>(
        MaterialPageRoute(
          builder: (_) => const DocumentPagesCaptureScreen(
            title: 'Capture Score Sheet',
            instructions: 'Photograph each page of the score sheet — handwritten or typed, any layout.',
          ),
        ),
      );
      if (!mounted) return;
      if (pages == null || pages.isEmpty) {
        setState(() => _step = _Step.subject);
        return;
      }
      _capturedPages = pages;
      await _transcribe();
    } else {
      final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png']);
      if (result.isEmpty || !mounted) return;
      final files = [for (final f in result) File(f.path!)];
      setState(() {
        _capturedPages = files;
        _step = _Step.capturing;
      });
      await _transcribe();
    }
  }

  Future<void> _transcribe() async {
    setState(() {
      _transcribing = true;
      _statusText = 'Starting…';
    });
    try {
      final table = await _transcriptionService.transcribe(
        _capturedPages,
        onProgress: (status) {
          if (mounted) setState(() => _statusText = status);
        },
      );
      final roster = await _repository.listLearners(widget.reportClass.id);
      final extracted = _extractNameScorePairs(table);
      final matches = await _repository.matchNamesAgainstRoster(widget.reportClass.id, extracted);
      if (!mounted) return;
      setState(() {
        _roster = roster;
        _aiNotes = table.notes;
        _rows
          ..clear()
          ..addAll([
            for (final m in matches)
              _ScoreRowState(name: m.extractedName, score: m.extractedScore ?? '', matchedLearner: m.matchedLearner),
          ]);
        _step = _Step.review;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _step = _Step.transcribeError;
        _lastError = error.toString();
      });
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  /// Best-effort column detection (name column: header contains "name";
  /// score column: header contains "score"/"mark"/"total") — a starting
  /// point only, every row is reviewed and correctable on the Stage 4
  /// screen regardless of whether this guessed right.
  List<({String name, String? score})> _extractNameScorePairs(TranscribedTable table) {
    int? nameCol;
    int? scoreCol;
    for (var i = 0; i < table.headers.length; i++) {
      final h = table.headers[i].toLowerCase();
      if (nameCol == null && h.contains('name')) nameCol = i;
      if (scoreCol == null && (h.contains('score') || h.contains('mark') || h.contains('total'))) scoreCol = i;
    }
    return [
      for (final row in table.rows)
        (
          name: nameCol != null && nameCol < row.length ? row[nameCol] : (row.isNotEmpty ? row[0] : ''),
          score: scoreCol != null && scoreCol < row.length ? row[scoreCol] : (row.length > 1 ? row[1] : null),
        ),
    ];
  }

  Future<void> _retry() async {
    setState(() => _step = _Step.capturing);
    await _transcribe();
  }

  Future<void> _resolveUnmatchedRow(_ScoreRowState row) async {
    final choice = await showDialog<ReportLearner?>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Who is "${row.name.text}"?'),
        children: [
          for (final learner in _roster)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(learner),
              child: Text(learner.fullName),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice != null) {
      setState(() {
        row.matchedLearner = choice;
        row.confirmedAsNew = false;
      });
    }
  }

  void _confirmAsNewLearner(_ScoreRowState row) => setState(() => row.confirmedAsNew = true);

  bool get _allResolved => _rows.every((r) => r.isResolved);

  Future<void> _confirmAndSave() async {
    if (_rows.isEmpty || !_allResolved) return;
    for (final row in _rows) {
      if (double.tryParse(row.score.text.trim()) == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${row.name.text}" needs a numeric score.')),
        );
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final subject = await _repository.getOrCreateSubject(widget.reportClass.id, _subjectController.text);
      for (final row in _rows) {
        var learner = row.matchedLearner;
        if (learner == null && row.confirmedAsNew) {
          learner = await _repository.addLearner(widget.reportClass.id, row.name.text);
        }
        if (learner == null) continue; // shouldn't happen — guarded by _allResolved
        final score = double.parse(row.score.text.trim());
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
      appBar: AppBar(title: const Text('Upload Subject Score Sheet')),
      body: switch (_step) {
        _Step.subject => _buildSubjectStep(context),
        _Step.capturing => Center(
            child: _transcribing
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(_statusText.isEmpty ? 'Reading the score sheet…' : _statusText),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        _Step.transcribeError => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 12),
                  Text('Could not read this score sheet: $_lastError', textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _retry, child: const Text('Try Again')),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => setState(() => _step = _Step.subject),
                    child: const Text('Re-capture Instead'),
                  ),
                ],
              ),
            ),
          ),
        _Step.review => _buildReview(context),
      },
    );
  }

  Widget _buildSubjectStep(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Which subject is this score sheet for?', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _subjectController,
            decoration: const InputDecoration(labelText: 'Subject', border: OutlineInputBorder()),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _chooseCaptureMethod,
            icon: const Icon(Icons.add_a_photo_outlined),
            label: const Text('Capture / Upload Score Sheet'),
          ),
        ],
      ),
    );
  }

  Widget _buildReview(BuildContext context) {
    return Column(
      children: [
        if (_capturedPages.isNotEmpty)
          SizedBox(
            height: 90,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final page in _capturedPages)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => _showFullImage(context, page),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(page, height: 74, width: 74, fit: BoxFit.cover),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (_aiNotes case final notes? when notes.trim().isNotEmpty)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.tertiaryContainer,
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.auto_awesome_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(notes, style: Theme.of(context).textTheme.bodySmall)),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Review every row against the photo above — correct anything misread, and resolve any name '
            'that couldn\'t be matched to the roster.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [for (var i = 0; i < _rows.length; i++) _buildRowCard(context, i)],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _saving || !_allResolved ? null : _confirmAndSave,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(_saving
                  ? 'Saving…'
                  : _allResolved
                      ? 'Confirm & Save ${_rows.length} Score(s)'
                      : 'Resolve every row before saving'),
            ),
          ),
        ),
      ],
    );
  }

  void _showFullImage(BuildContext context, File file) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(child: InteractiveViewer(child: Image.file(file))),
    );
  }

  Widget _buildRowCard(BuildContext context, int index) {
    final row = _rows[index];
    final unresolved = !row.isResolved;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: unresolved ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.35) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: row.name,
                    decoration: const InputDecoration(labelText: 'Name', isDense: true, border: OutlineInputBorder()),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: row.score,
                    decoration: const InputDecoration(labelText: 'Score', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (row.matchedLearner != null)
              Row(
                children: [
                  const Icon(Icons.check_circle, size: 16, color: Colors.green),
                  const SizedBox(width: 4),
                  Expanded(child: Text('Matched to ${row.matchedLearner!.fullName}', style: Theme.of(context).textTheme.bodySmall)),
                ],
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(
                    row.confirmedAsNew ? Icons.person_add_alt_1 : Icons.warning_amber_rounded,
                    size: 16,
                    color: row.confirmedAsNew ? Colors.green : Theme.of(context).colorScheme.error,
                  ),
                  Text(
                    row.confirmedAsNew ? 'Confirmed as a new roster learner' : 'No roster match found',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_roster.isNotEmpty)
                    TextButton(onPressed: () => _resolveUnmatchedRow(row), child: const Text('Pick existing learner')),
                  if (!row.confirmedAsNew)
                    TextButton(onPressed: () => _confirmAsNewLearner(row), child: const Text('Add as new learner')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

enum _CaptureMethod { camera, device }
