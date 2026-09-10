import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/marking_rubric.dart';
import '../models/marking_script.dart';
import 'concise_marking_service.dart';
import 'concise_score_calculator.dart';

/// "Concise Marking" (Scan Marker, 2026-09-11, per explicit request) —
/// draws a real tick (✓, green) or cross (✗, red) directly onto a COPY of
/// a script's own photographed page, right at the real answer's own
/// location, plus the marks awarded ("3/5") next to it — "a tick on the
/// correct answer on the image of the student's script right on the
/// correct question's answer being marked, or an x... if it is a wrong
/// one." Originals are never touched; annotated pages are new files.
///
/// [annotatePages] only draws where [AnswerAnnotation.hasLocation] is
/// true — every answer the AI couldn't confidently place (see
/// gradeMarkingScriptConcise's own Cloud Function comment: it's told to
/// return null rather than guess) is instead collected by
/// [generateFallbackReproduction] into a plain, separately generated
/// document, per the explicit request: "if there is no AI to make a
/// representation on the actual image... the computer should mark the
/// question on the computer generated version of the script... but let
/// the marking be shown on the actual answer or right next to the answer
/// clearly showing which answer is being marked."
class ScriptAnnotationService {
  static const _markFontSize = 34.0;
  static const _scoreFontSize = 20.0;

  String _formatMark(double m) => m == m.roundToDouble() ? m.toInt().toString() : m.toString();

  /// Replaces characters the PDF's default font (Helvetica) has no glyph
  /// for — an em/en-dash being the one a real title string (built from a
  /// student name + scheme title elsewhere in this app) is most likely to
  /// contain — with a plain ASCII equivalent, defensively, regardless of
  /// what the caller passes in.
  String _pdfSafe(String text) => text.replaceAll('—', '-').replaceAll('–', '-');

  /// One output PNG per page that had at least one confidently-located
  /// mark drawn on it — pages with none are skipped entirely (nothing to
  /// add). [pageFiles] is a script's own real captured pages, in order;
  /// [annotations] pairs by [AnswerAnnotation.questionLabel] with
  /// [answers] to know whether each mark is a tick or a cross and what
  /// score to print.
  Future<List<File>> annotatePages({
    required List<File> pageFiles,
    required List<GradedAnswer> answers,
    required List<AnswerAnnotation> annotations,
    required Directory outputDir,
    ConciseScore? score,
  }) async {
    final answerByLabel = {for (final a in answers) a.questionLabel: a};
    final byPage = <int, List<(GradedAnswer, AnswerAnnotation)>>{};
    for (final ann in annotations) {
      if (!ann.hasLocation) continue;
      final answer = answerByLabel[ann.questionLabel];
      if (answer == null) continue;
      byPage.putIfAbsent(ann.pageIndex!, () => []).add((answer, ann));
    }

    // "Add the total number of marks when you are done marking" — stamped
    // on page 1 (index 0). Force page 0 into the output even if it had no
    // per-answer marks, so the total always lands somewhere visible.
    if (score != null && pageFiles.isNotEmpty) byPage.putIfAbsent(0, () => []);

    final outputFiles = <File>[];
    final orderedPages = byPage.keys.toList()..sort();
    for (final pageIndex in orderedPages) {
      if (pageIndex < 0 || pageIndex >= pageFiles.length) continue;
      final original = pageFiles[pageIndex];
      if (!await original.exists()) continue;

      final pngBytes = await _drawOnPage(
        original,
        byPage[pageIndex]!,
        scoreStamp: pageIndex == 0 ? score : null,
      );
      final outFile = File(p.join(outputDir.path, 'page_${(pageIndex + 1).toString().padLeft(2, '0')}_marked.png'));
      await outFile.writeAsBytes(pngBytes, flush: true);
      outputFiles.add(outFile);
    }
    return outputFiles;
  }

  Future<Uint8List> _drawOnPage(
    File original,
    List<(GradedAnswer, AnswerAnnotation)> marks, {
    ConciseScore? scoreStamp,
  }) async {
    final bytes = await original.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final width = image.width.toDouble();
    final height = image.height.toDouble();

    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, width, height));
      canvas.drawImage(image, ui.Offset.zero, ui.Paint());

      for (final (answer, ann) in marks) {
        final isZero = answer.marksAwarded <= 0;
        final color = isZero ? const ui.Color(0xFFD32F2F) : const ui.Color(0xFF2E7D32);
        final symbol = isZero ? '✗' : '✓';
        final scoreText = '${_formatMark(answer.marksAwarded)}/${_formatMark(answer.maxMarks)}';

        final painter = TextPainter(
          text: TextSpan(children: [
            TextSpan(text: symbol, style: TextStyle(color: color, fontSize: _markFontSize, fontWeight: FontWeight.w900)),
            TextSpan(text: ' $scoreText', style: TextStyle(color: color, fontSize: _scoreFontSize, fontWeight: FontWeight.w700)),
          ]),
          textDirection: TextDirection.ltr,
        )..layout();

        // Placed just outside the answer's own bounding box (right edge,
        // top-aligned) — "right on the correct question's answer... or
        // right next to the answer" — clear of the handwriting itself
        // rather than drawn over it, which would make the original
        // answer harder to read back.
        final x = ((ann.xMax! / 1000.0) * width).clamp(0.0, width - painter.width - 8);
        final y = ((ann.yMin! / 1000.0) * height).clamp(0.0, height - painter.height - 6);

        // A translucent white backing so the mark stays legible over
        // whatever real content (ruled lines, ink, shadows) sits behind
        // it on the actual photographed page.
        canvas.drawRect(
          ui.Rect.fromLTWH(x - 4, y - 3, painter.width + 8, painter.height + 6),
          ui.Paint()..color = const ui.Color(0xE6FFFFFF),
        );
        painter.paint(canvas, ui.Offset(x, y));
      }

      if (scoreStamp != null) {
        _drawScoreStamp(canvas, scoreStamp, width, height);
      }

      final picture = recorder.endRecording();
      final outImage = await picture.toImage(width.round(), height.round());
      try {
        final byteData = await outImage.toByteData(format: ui.ImageByteFormat.png);
        return byteData!.buffer.asUint8List();
      } finally {
        outImage.dispose();
      }
    } finally {
      image.dispose();
    }
  }

  /// The out-of-100 score panel drawn onto page 1 of the marked script —
  /// "add the total number of marks when you are done marking... all final
  /// total marks for the paper must be calculated in percentage".
  void _drawScoreStamp(ui.Canvas canvas, ConciseScore score, double width, double height) {
    final margin = width * 0.03;
    final panelW = (width * 0.46).clamp(260.0, width - margin * 2);
    final bigSize = (width * 0.05).clamp(22.0, 60.0);
    final smallSize = (width * 0.022).clamp(11.0, 24.0);
    const red = ui.Color(0xFFD32F2F);
    const ink = ui.Color(0xFF1A1A1A);

    final spans = <InlineSpan>[
      TextSpan(text: 'SCORE\n', style: TextStyle(color: red, fontSize: smallSize, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
      TextSpan(text: '${score.outOf100Label}\n', style: TextStyle(color: red, fontSize: bigSize, fontWeight: FontWeight.w900)),
      TextSpan(
        text: '${score.rawFractionLabel} raw  ·  ${score.roundedPercent}%'
            '${score.rubricApplied ? '' : '  (no section rules)'}',
        style: TextStyle(color: ink, fontSize: smallSize, fontWeight: FontWeight.w600),
      ),
    ];
    if (score.sections.length > 1) {
      spans.add(TextSpan(text: '\n', style: TextStyle(fontSize: smallSize * 0.5)));
      for (final s in score.sections) {
        spans.add(TextSpan(
          text: '\n${s.name}: ${ConciseScore.fmt(s.awarded)}/${ConciseScore.fmt(s.possible)}'
              '${s.ignoredExcessQuestions > 0 ? ' (best ${s.countedQuestions})' : ''}',
          style: TextStyle(color: ink, fontSize: smallSize * 0.92, fontWeight: FontWeight.w500),
        ));
      }
    }

    final painter = TextPainter(
      text: TextSpan(children: spans),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    )..layout(maxWidth: panelW - 24);

    final panelH = painter.height + 24;
    final left = width - panelW - margin;
    final top = margin;
    final rect = ui.Rect.fromLTWH(left, top, panelW, panelH);
    canvas.drawRect(rect, ui.Paint()..color = const ui.Color(0xF2FFFFFF));
    canvas.drawRect(
      rect.deflate(1.5),
      ui.Paint()
        ..color = red
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    painter.paint(canvas, ui.Offset(left + 12, top + 12));
  }

  /// A one-page "brief report of the student's performance in all sections
  /// of the exam" (per explicit request) — the score breakdown plus the
  /// AI's observation bullets (already capped at 10), rendered as a PDF
  /// page that travels with the marked script. Always produced (unlike the
  /// fallback page, which only appears when some answers weren't locatable).
  Future<File> generateMarkedReportPdf({
    required ConciseScore score,
    required List<String> observations,
    required String title,
    String? subjectName,
    String? studentName,
    MarkingRubric? rubric,
    required Directory outputDir,
  }) async {
    final doc = pw.Document();
    final bullets = observations.take(10).toList();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(level: 0, text: _pdfSafe(title)),
          if (subjectName != null && subjectName.trim().isNotEmpty)
            pw.Text(_pdfSafe(subjectName), style: const pw.TextStyle(fontSize: 11)),
          if (studentName != null && studentName.trim().isNotEmpty)
            pw.Text(_pdfSafe('Candidate: $studentName'), style: const pw.TextStyle(fontSize: 11)),
          pw.SizedBox(height: 10),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.red700, width: 1.5)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('SCORE: ${score.outOf100Label}',
                    style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: PdfColors.red700)),
                pw.Text('${score.rawFractionLabel} raw marks  ·  ${score.roundedPercent}%',
                    style: const pw.TextStyle(fontSize: 11)),
                if (!score.rubricApplied)
                  pw.Text('No cover-page section rules were found - this is a straight percentage of every graded answer.',
                      style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
              ],
            ),
          ),
          pw.SizedBox(height: 12),
          if (score.sections.isNotEmpty) ...[
            pw.Text('By section', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                  children: [
                    _reportCell('Section', bold: true),
                    _reportCell('Questions marked', bold: true),
                    _reportCell('Marks', bold: true),
                    _reportCell('%', bold: true),
                  ],
                ),
                for (final s in score.sections)
                  pw.TableRow(children: [
                    _reportCell(s.name),
                    _reportCell(s.ignoredExcessQuestions > 0
                        ? '${s.countedQuestions} counted (best of ${s.countedQuestions + s.ignoredExcessQuestions})'
                        : '${s.countedQuestions}'),
                    _reportCell('${ConciseScore.fmt(s.awarded)} / ${ConciseScore.fmt(s.possible)}'),
                    _reportCell('${s.percentage.round()}%'),
                  ]),
              ],
            ),
            pw.SizedBox(height: 12),
          ],
          pw.Text('Performance report', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          if (bullets.isEmpty)
            pw.Text('No observations were returned for this script.', style: const pw.TextStyle(fontSize: 10))
          else
            for (final b in bullets)
              pw.Bullet(text: _pdfSafe(b), style: const pw.TextStyle(fontSize: 10)),
          if (rubric != null && rubric.instructionsSummary.trim().isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text('Marking rules read from the cover page',
                style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
            pw.Text(_pdfSafe(rubric.instructionsSummary), style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          ],
        ],
      ),
    );

    final bytes = await doc.save();
    final safeName = title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final file = File(p.join(outputDir.path, '${safeName.isEmpty ? 'script' : safeName}_report.pdf'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  pw.Widget _reportCell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : null)),
      );

  /// The "computer generated version of the script" fallback (per
  /// explicit request, see this class's own doc comment) — one page,
  /// every answer the AI couldn't confidently place on the real photo,
  /// each with its own real tick/cross and score printed directly beside
  /// its own transcribed answer text. Null when every answer WAS placed
  /// (nothing to fall back for).
  Future<File?> generateFallbackReproduction({
    required List<GradedAnswer> answers,
    required List<AnswerAnnotation> annotations,
    required Directory outputDir,
    required String title,
  }) async {
    final locatedLabels = {for (final a in annotations) if (a.hasLocation) a.questionLabel};
    final unlocated = [for (final a in answers) if (!locatedLabels.contains(a.questionLabel)) a];
    if (unlocated.isEmpty) return null;

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          // The default PDF font (Helvetica) has no Unicode glyphs for an
          // em-dash or similar — this bundled `pdf` package limitation
          // already exists elsewhere in this app's other PDF generators
          // too, not something new here; kept in scope by simply avoiding
          // the unsupported character in THIS new text, rather than
          // taking on bundling a Unicode-capable font project-wide.
          pw.Header(level: 0, text: _pdfSafe(title)),
          pw.Paragraph(
            text: 'Marked here instead of directly on the photographed page - the AI was not confident '
                'enough of exactly where these answers sit on the original image to mark them there directly.',
            style: pw.TextStyle(fontSize: 10, fontStyle: pw.FontStyle.italic),
          ),
          pw.SizedBox(height: 12),
          for (final a in unlocated)
            pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 10),
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.5)),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(a.questionLabel, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      pw.Text(
                        '${a.marksAwarded <= 0 ? 'X' : 'v'}  ${a.marksAwarded == a.marksAwarded.roundToDouble() ? a.marksAwarded.toInt() : a.marksAwarded}/'
                        '${a.maxMarks == a.maxMarks.roundToDouble() ? a.maxMarks.toInt() : a.maxMarks}',
                        style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold,
                          color: a.marksAwarded <= 0 ? PdfColors.red700 : PdfColors.green700,
                        ),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(a.transcribedAnswer.isEmpty ? '(no answer found)' : a.transcribedAnswer),
                ],
              ),
            ),
        ],
      ),
    );

    final bytes = await doc.save();
    final safeName = title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final file = File(p.join(outputDir.path, '${safeName.isEmpty ? 'script' : safeName}_unmarked_on_photo.pdf'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}
