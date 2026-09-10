import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/marking_script.dart';
import 'concise_marking_service.dart';

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
  }) async {
    final answerByLabel = {for (final a in answers) a.questionLabel: a};
    final byPage = <int, List<(GradedAnswer, AnswerAnnotation)>>{};
    for (final ann in annotations) {
      if (!ann.hasLocation) continue;
      final answer = answerByLabel[ann.questionLabel];
      if (answer == null) continue;
      byPage.putIfAbsent(ann.pageIndex!, () => []).add((answer, ann));
    }

    final outputFiles = <File>[];
    for (final entry in byPage.entries) {
      final pageIndex = entry.key;
      if (pageIndex < 0 || pageIndex >= pageFiles.length) continue;
      final original = pageFiles[pageIndex];
      if (!await original.exists()) continue;

      final pngBytes = await _drawOnPage(original, entry.value);
      final outFile = File(p.join(outputDir.path, 'page_${(pageIndex + 1).toString().padLeft(2, '0')}_marked.png'));
      await outFile.writeAsBytes(pngBytes, flush: true);
      outputFiles.add(outFile);
    }
    return outputFiles;
  }

  Future<Uint8List> _drawOnPage(File original, List<(GradedAnswer, AnswerAnnotation)> marks) async {
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
