import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/home_assignment.dart';

/// Home Assignment epic (2026-09-16, per explicit request) — a plain
/// shareable score list for one assignment's batch review, separate from
/// [MarksheetDocumentService]: that service needs `MarkingScript`-shaped
/// data (split first/surname, gender, a reviewed-status gate) which
/// [HomeAssignmentSubmission] simply doesn't have (one `learnerName`, no
/// gender, `status: queued|marked|sent` instead). This is for the
/// teacher's own distribution (email/WhatsApp/download) — never sent to
/// pupils, unlike "Approve & Send Batch" which delivers individual
/// results via the Cloud Function.
class HomeAssignmentScoreListDocumentService {
  /// Every MARKED submission — `status` `marked` or `sent`; `queued` is
  /// skipped since it has no score yet — sorted alphabetically by
  /// [HomeAssignmentSubmission.learnerName] (no split name to sort by
  /// surname, unlike the MarkingScript-based marksheet).
  List<HomeAssignmentSubmission> _scoredSubmissions(List<HomeAssignmentSubmission> submissions) {
    final scored = submissions.where((s) => s.status != HomeAssignmentSubmissionStatus.queued && s.score != null && s.maxScore != null).toList();
    scored.sort((a, b) => a.learnerName.toLowerCase().compareTo(b.learnerName.toLowerCase()));
    return scored;
  }

  String _fmt(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);

  String _percentLabel(HomeAssignmentSubmission s) {
    if (s.maxScore == null || s.maxScore == 0) return '—';
    return '${_fmt((s.score! / s.maxScore!) * 100)}%';
  }

  Future<Uint8List> buildPdf({
    required IssuedHomeAssignment assignment,
    required List<HomeAssignmentSubmission> submissions,
  }) async {
    final scored = _scoredSubmissions(submissions);
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (context) => context.pageNumber == 1
            ? pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('HOME ASSIGNMENT SCORE LIST', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  pw.Text('${assignment.title}  ·  ${assignment.subjectName}  ·  ${assignment.className}', style: const pw.TextStyle(fontSize: 11)),
                  if (assignment.referenceCode != null) pw.Text('Reference code: ${assignment.referenceCode}', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                  pw.SizedBox(height: 10),
                ],
              )
            : pw.SizedBox(),
        build: (context) => [
          pw.Table(
            border: pw.TableBorder.all(width: 0.5),
            columnWidths: const {0: pw.FlexColumnWidth(2.5), 1: pw.FlexColumnWidth(1.2), 2: pw.FlexColumnWidth(1)},
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [_pdfCell('Learner', bold: true), _pdfCell('Score', bold: true), _pdfCell('Percentage', bold: true)],
              ),
              for (final s in scored)
                pw.TableRow(
                  children: [
                    _pdfCell(s.learnerName),
                    _pdfCell('${_fmt(s.score!)} / ${_fmt(s.maxScore!)}'),
                    _pdfCell(_percentLabel(s), bold: true),
                  ],
                ),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Text(
            '${scored.length} learner(s) marked'
            '${submissions.length - scored.length > 0 ? ' · ${submissions.length - scored.length} still queued (excluded)' : ''}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
        ],
      ),
    );

    return doc.save();
  }

  pw.Widget _pdfCell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : null)),
      );
}
