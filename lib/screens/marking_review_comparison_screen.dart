import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/concise_marking_record.dart';
import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/concise_score_calculator.dart';
import '../services/marking_script_repository.dart';
import '../services/question_review_index.dart';

/// Pure geometry (unit-tested separately, see marking_review_comparison_screen_test.dart):
/// a Matrix4 for an [InteractiveViewer] that centres and reasonably fills
/// [normBox] (0-1000-normalized, same convention as [ScriptAnnotationRecord])
/// within [viewport], given the image is laid out with BoxFit.contain at
/// [imageSize]'s own aspect ratio. Never zooms below 1x (fit-to-view) or
/// above 6x (a tiny box shouldn't zoom in absurdly far).
Matrix4 fitBoxTransform({required Size viewport, required Size imageSize, required Rect normBox}) {
  if (viewport.width <= 0 || viewport.height <= 0 || imageSize.width <= 0 || imageSize.height <= 0) {
    return Matrix4.identity();
  }
  final imageAspect = imageSize.width / imageSize.height;
  final viewportAspect = viewport.width / viewport.height;
  double displayedW, displayedH, offsetX, offsetY;
  if (imageAspect > viewportAspect) {
    displayedW = viewport.width;
    displayedH = displayedW / imageAspect;
    offsetX = 0;
    offsetY = (viewport.height - displayedH) / 2;
  } else {
    displayedH = viewport.height;
    displayedW = displayedH * imageAspect;
    offsetY = 0;
    offsetX = (viewport.width - displayedW) / 2;
  }

  final boxLeft = offsetX + (normBox.left / 1000.0) * displayedW;
  final boxTop = offsetY + (normBox.top / 1000.0) * displayedH;
  final boxRight = offsetX + (normBox.right / 1000.0) * displayedW;
  final boxBottom = offsetY + (normBox.bottom / 1000.0) * displayedH;
  final boxW = (boxRight - boxLeft).abs().clamp(1.0, viewport.width);
  final boxH = (boxBottom - boxTop).abs().clamp(1.0, viewport.height);
  final boxCenter = Offset((boxLeft + boxRight) / 2, (boxTop + boxBottom) / 2);

  // Fill about 40% of the viewport's shorter side with the box.
  final scaleForW = (viewport.width * 0.4) / boxW;
  final scaleForH = (viewport.height * 0.4) / boxH;
  final scale = (scaleForW < scaleForH ? scaleForW : scaleForH).clamp(1.0, 6.0);

  final viewportCenter = Offset(viewport.width / 2, viewport.height / 2);
  final translation = viewportCenter - boxCenter * scale;
  return Matrix4.identity()
    ..translateByDouble(translation.dx, translation.dy, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1);
}

/// Pixel rectangle of a 0-1000-normalized box within an image laid out with
/// BoxFit.contain at [imageSize] inside [viewport] — what draws the Stage 8
/// highlight outline at the right spot regardless of letterboxing.
Rect boxToViewportRect({required Size viewport, required Size imageSize, required Rect normBox}) {
  if (viewport.width <= 0 || viewport.height <= 0 || imageSize.width <= 0 || imageSize.height <= 0) return Rect.zero;
  final imageAspect = imageSize.width / imageSize.height;
  final viewportAspect = viewport.width / viewport.height;
  double displayedW, displayedH, offsetX, offsetY;
  if (imageAspect > viewportAspect) {
    displayedW = viewport.width;
    displayedH = displayedW / imageAspect;
    offsetX = 0;
    offsetY = (viewport.height - displayedH) / 2;
  } else {
    displayedH = viewport.height;
    displayedW = displayedH * imageAspect;
    offsetY = 0;
    offsetX = (viewport.width - displayedW) / 2;
  }
  return Rect.fromLTRB(
    offsetX + (normBox.left / 1000.0) * displayedW,
    offsetY + (normBox.top / 1000.0) * displayedH,
    offsetX + (normBox.right / 1000.0) * displayedW,
    offsetY + (normBox.bottom / 1000.0) * displayedH,
  );
}

/// Marking Reliability Stages 6-11 (2026-09-22, per explicit request,
/// following a real incident where a section-structure bug produced an
/// out-of-range score — see ConciseScoreCalculator's Stage 2 safeguard, and
/// [QuestionReviewIndex] for Stage 5's data layer this screen navigates).
///
/// The marking key/question-paper source (LEFT pane by default) and the
/// marked script (RIGHT pane) are shown together, both scrolled to the
/// currently selected question at once — tapping a question number in the
/// strip along the top moves both. Each pane zooms/pans independently
/// (Stage 7), resetting to a sensible default on every question change.
/// Only the RIGHT pane can show a highlighted box (Stage 8): the AI is
/// never asked to locate a question ON the key/question-paper image, only
/// on the student's own script — see [QuestionReviewIndex]'s own doc
/// comment on why that source is offered as a page to flip to, not an
/// auto-highlighted spot.
class MarkingReviewComparisonScreen extends StatefulWidget {
  const MarkingReviewComparisonScreen({
    super.key,
    required this.script,
    required this.scriptPageFiles,
    this.questionPaperFiles = const [],
    this.scheme,
    this.repository,
    this.initialQuestionLabel,
  });

  final MarkingScript script;
  final List<File> scriptPageFiles;
  final List<File> questionPaperFiles;
  final MarkingScheme? scheme;
  final MarkingScriptRepository? repository;

  /// Which question to open on — set by Stage 12's routing (e.g. the
  /// question the Stage 2 safeguard named as the likely culprit).
  final String? initialQuestionLabel;

  @override
  State<MarkingReviewComparisonScreen> createState() => _MarkingReviewComparisonScreenState();
}

class _MarkingReviewComparisonScreenState extends State<MarkingReviewComparisonScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late List<GradedAnswer> _answers;
  ConciseMarkingRecord? _record;
  late QuestionReviewIndex _index;
  int _selected = 0;
  bool _stacked = false;
  bool _saving = false;

  final _keyTransform = TransformationController();
  final _scriptTransform = TransformationController();
  final _keyPaneKey = GlobalKey();
  final _scriptPaneKey = GlobalKey();
  final _markController = TextEditingController();
  final Map<String, Size> _imageSizeCache = {};

  @override
  void initState() {
    super.initState();
    _answers = List.of(widget.script.gradedAnswers ?? const <GradedAnswer>[]);
    _record = widget.script.conciseMarking;
    _rebuildIndex();
    if (widget.initialQuestionLabel != null) {
      final i = _index.indexOfLabel(widget.initialQuestionLabel!);
      if (i >= 0) _selected = i;
    }
    _syncMarkController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resetZoomForSelection());
  }

  @override
  void dispose() {
    _keyTransform.dispose();
    _scriptTransform.dispose();
    _markController.dispose();
    super.dispose();
  }

  void _rebuildIndex() {
    _index = QuestionReviewIndex.build(
      answers: _answers,
      annotations: _record?.annotations ?? const [],
      scheme: widget.scheme,
      questionPaperImageCount: widget.questionPaperFiles.length,
    );
  }

  void _syncMarkController() {
    final mark = _index.entryAt(_selected)?.answer?.marksAwarded ?? 0;
    _markController.text = _fmt(mark);
  }

  static String _fmt(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toString();

  void _selectQuestion(int i) {
    if (i == _selected || i < 0 || i >= _index.length) return;
    setState(() {
      _selected = i;
      _syncMarkController();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _resetZoomForSelection());
  }

  Future<Size?> _sizeOf(File file) async {
    final cached = _imageSizeCache[file.path];
    if (cached != null) return cached;
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      _imageSizeCache[file.path] = size;
      return size;
    } catch (_) {
      return null;
    }
  }

  static File? _fileAt(List<File> files, int? index) => (index != null && index >= 0 && index < files.length) ? files[index] : null;

  /// Stage 7: reset both panes' zoom on every question change — fit-to-
  /// bounding-box on the script pane when a real location exists, plain
  /// fit-to-view otherwise (and always for the key pane, which never has a
  /// located box — see class doc).
  Future<void> _resetZoomForSelection() async {
    if (!mounted) return;
    _keyTransform.value = Matrix4.identity();
    _scriptTransform.value = Matrix4.identity();
    final entry = _index.entryAt(_selected);
    final loc = entry?.scriptLocation;
    if (entry == null || loc == null || !loc.hasLocation) return;
    final file = _fileAt(widget.scriptPageFiles, loc.pageIndex);
    if (file == null) return;
    final imageSize = await _sizeOf(file);
    if (!mounted || imageSize == null) return;
    final box = _scriptPaneKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final matrix = fitBoxTransform(
      viewport: box.size,
      imageSize: imageSize,
      normBox: Rect.fromLTRB(loc.xMin!.toDouble(), loc.yMin!.toDouble(), loc.xMax!.toDouble(), loc.yMax!.toDouble()),
    );
    if (mounted) setState(() => _scriptTransform.value = matrix);
  }

  /// Stage 10: correct the mark for the currently selected question without
  /// leaving this screen. Reuses the same approach the batch review flow's
  /// own mark-editing already relies on (MarkingReviewScreen: edit, clamp
  /// to maxMarks, persist) — except the score is recomputed against the
  /// SAME rubric that produced the original score (now persisted, see
  /// ConciseMarkingRecord.rubric), which also re-runs the Stage 2 safeguard
  /// on the corrected figures for free.
  Future<void> _saveMark() async {
    final entry = _index.entryAt(_selected);
    final answer = entry?.answer;
    if (answer == null) return;
    final parsed = double.tryParse(_markController.text.trim());
    if (parsed == null || parsed.isNaN || parsed < 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid, non-negative mark.')));
      return;
    }
    final clamped = parsed.clamp(0, answer.maxMarks).toDouble();
    if (clamped == answer.marksAwarded) return; // nothing changed

    setState(() => _saving = true);
    final updatedAnswers = [
      for (final a in _answers)
        if (a.questionLabel == answer.questionLabel) a.copyWith(marksAwarded: clamped, teacherEdited: true) else a,
    ];
    final record = _record;
    final newScore = const ConciseScoreCalculator().compute(
      answers: updatedAnswers,
      sectionByLabel: record?.sectionByLabel ?? const {},
      rubric: record?.rubric,
    );
    final newRecord = record == null
        ? null
        : ConciseMarkingRecord(
            markedAt: record.markedAt,
            engine: record.engine,
            annotations: record.annotations,
            scoreJson: newScore.toJson(),
            sectionByLabel: record.sectionByLabel,
            rubric: record.rubric,
          );

    try {
      await _repository.update(widget.script.copyWith(gradedAnswers: updatedAnswers, conciseMarking: newRecord));
      if (!mounted) return;
      setState(() {
        _answers = updatedAnswers;
        _record = newRecord;
        _rebuildIndex();
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mark saved.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_index.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Review')),
        body: const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No graded questions to review.'))),
      );
    }
    final entry = _index.entryAt(_selected)!;
    final score = _record == null ? null : ConciseScore.fromJson(_record!.scoreJson);
    final name = '${widget.script.firstName} ${widget.script.surname}'.trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty ? 'Marking Review' : name),
        actions: [
          IconButton(
            key: const Key('layout-toggle'),
            tooltip: _stacked ? 'Side by side' : 'Stack the panes',
            icon: Icon(_stacked ? Icons.view_column_outlined : Icons.view_agenda_outlined),
            onPressed: () => setState(() => _stacked = !_stacked),
          ),
        ],
      ),
      body: Column(
        children: [
          if (score?.structureError == true) _structureErrorBanner(context, score!),
          _questionStrip(context),
          const Divider(height: 1),
          Expanded(child: _stacked ? _stackedPanes(entry) : _sideBySidePanes(entry)),
          const Divider(height: 1),
          _scoreOverlay(context, entry),
        ],
      ),
    );
  }

  Widget _structureErrorBanner(BuildContext context, ConciseScore score) => Container(
        width: double.infinity,
        color: Colors.amber.shade100,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.amber.shade900, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                score.structureErrorReason ?? "This script's total didn't add up correctly.",
                style: TextStyle(color: Colors.amber.shade900, fontSize: 12),
              ),
            ),
          ],
        ),
      );

  // Stage 6: the horizontal question-number strip. Tapping one moves both
  // panes and the score overlay to it together.
  Widget _questionStrip(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        key: const Key('question-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: _index.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final label = _index.orderedLabels[i];
          final selected = i == _selected;
          final flagged = _index.byLabel[label]?.answer?.confidence.name == 'low';
          return ChoiceChip(
            label: Text(label),
            selected: selected,
            avatar: flagged && !selected ? const Icon(Icons.priority_high_outlined, size: 14) : null,
            onSelected: (_) => _selectQuestion(i),
          );
        },
      ),
    );
  }

  Widget _sideBySidePanes(QuestionReviewEntry entry) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _keyPane(entry)),
          const VerticalDivider(width: 1),
          Expanded(child: _scriptPane(entry)),
        ],
      );

  Widget _stackedPanes(QuestionReviewEntry entry) => Column(
        children: [
          Expanded(child: _keyPane(entry)),
          const Divider(height: 1),
          Expanded(child: _scriptPane(entry)),
        ],
      );

  Widget _keyPane(QuestionReviewEntry entry) {
    final source = entry.keySource;
    switch (source.kind) {
      case QuestionKeySourceKind.schemeText:
        return Container(
          key: _keyPaneKey,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.all(16),
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Marking key — ${entry.questionLabel}', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Text(source.expectedAnswerText ?? ''),
              ],
            ),
          ),
        );
      case QuestionKeySourceKind.questionPaperImage:
        final index = source.imageIndex;
        if (index == null) {
          return _QuestionPaperPicker(key: _keyPaneKey, files: widget.questionPaperFiles, transform: _keyTransform);
        }
        final file = _fileAt(widget.questionPaperFiles, index);
        if (file == null) return _noKeySource();
        return _ImagePane(key: _keyPaneKey, file: file, transform: _keyTransform, highlight: null);
      case QuestionKeySourceKind.none:
        return _noKeySource();
    }
  }

  Widget _noKeySource() => Container(
        key: _keyPaneKey,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: const Text(
          'No marking key or question paper was attached for this script — nothing to compare against on this side.',
          textAlign: TextAlign.center,
        ),
      );

  Widget _scriptPane(QuestionReviewEntry entry) {
    final loc = entry.scriptLocation;
    final file = _fileAt(widget.scriptPageFiles, loc?.pageIndex);
    if (file == null) {
      return Container(
        key: _scriptPaneKey,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: const Text("This answer's location on the script wasn't confidently identified.", textAlign: TextAlign.center),
      );
    }
    final box = (loc!.hasLocation)
        ? Rect.fromLTRB(loc.xMin!.toDouble(), loc.yMin!.toDouble(), loc.xMax!.toDouble(), loc.yMax!.toDouble())
        : null;
    return _ImagePane(key: _scriptPaneKey, file: file, transform: _scriptTransform, highlight: box, sizeResolver: _sizeOf);
  }

  // Stage 9 (score/comment) + Stage 10 (quick correction).
  Widget _scoreOverlay(BuildContext context, QuestionReviewEntry entry) {
    final answer = entry.answer;
    return Container(
      padding: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Question ${entry.questionLabel}', style: Theme.of(context).textTheme.titleSmall),
          if (answer != null) ...[
            const SizedBox(height: 4),
            Text(answer.transcribedAnswer.isEmpty ? '(no answer transcribed)' : answer.transcribedAnswer, maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: TextField(
                    key: const Key('mark-field'),
                    controller: _markController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: 'Mark (of ${_fmt(answer.maxMarks)})', isDense: true, border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _saving ? null : _saveMark,
                  icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save'),
                ),
                const SizedBox(width: 12),
                Chip(label: Text(answer.confidence.name), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One zoomable/pannable pane (Stage 7): an image with an optional
/// highlight outline (Stage 8) drawn at the right spot once the image's
/// real pixel size is known.
class _ImagePane extends StatefulWidget {
  const _ImagePane({super.key, required this.file, required this.transform, this.highlight, this.sizeResolver});

  final File file;
  final TransformationController transform;
  final Rect? highlight;
  final Future<Size?> Function(File file)? sizeResolver;

  @override
  State<_ImagePane> createState() => _ImagePaneState();
}

class _ImagePaneState extends State<_ImagePane> {
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _resolveSize();
  }

  @override
  void didUpdateWidget(covariant _ImagePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) _resolveSize();
  }

  Future<void> _resolveSize() async {
    final resolver = widget.sizeResolver;
    if (resolver == null || widget.highlight == null) return;
    final size = await resolver(widget.file);
    if (mounted) setState(() => _imageSize = size);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        return InteractiveViewer(
          transformationController: widget.transform,
          minScale: 0.5,
          maxScale: 8,
          child: SizedBox(
            width: viewport.width,
            height: viewport.height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(widget.file, fit: BoxFit.contain),
                if (widget.highlight != null && _imageSize != null)
                  Positioned.fromRect(
                    rect: boxToViewportRect(viewport: viewport, imageSize: _imageSize!, normBox: widget.highlight!),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: Colors.redAccent, width: 3), borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// When a question paper has several pages and it isn't known which one
/// holds the current question (see QuestionKeySourceKind.questionPaperImage's
/// own doc comment), the teacher flips through them manually here.
class _QuestionPaperPicker extends StatefulWidget {
  const _QuestionPaperPicker({super.key, required this.files, required this.transform});

  final List<File> files;
  final TransformationController transform;

  @override
  State<_QuestionPaperPicker> createState() => _QuestionPaperPickerState();
}

class _QuestionPaperPickerState extends State<_QuestionPaperPicker> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('No question paper pages attached.')));
    }
    return Column(
      children: [
        Expanded(child: _ImagePane(file: widget.files[_page.clamp(0, widget.files.length - 1)], transform: widget.transform)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(onPressed: _page > 0 ? () => setState(() => _page--) : null, icon: const Icon(Icons.chevron_left_outlined)),
              Text('Page ${_page + 1} of ${widget.files.length}'),
              IconButton(onPressed: _page < widget.files.length - 1 ? () => setState(() => _page++) : null, icon: const Icon(Icons.chevron_right_outlined)),
            ],
          ),
        ),
      ],
    );
  }
}
