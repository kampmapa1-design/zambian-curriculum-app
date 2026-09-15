import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/home_assignment.dart';

/// Home Assignment epic (2026-09-16, per explicit request: "scan marker
/// should also automatically generate a marking key for every home
/// assignment that it generates and share out that marking key through
/// the app's sharing means") — the plain, printable marking key PDF, kept
/// deliberately separate from [HomeAssignmentDocumentService]'s assignment
/// PDF: a subject teacher shares this with themselves or a co-marker, a
/// pupil never sees it. Same plain "working document, not a chat reply"
/// discipline as the assignment PDF it mirrors.
class HomeAssignmentMarkingKeyDocumentService {
  Future<Uint8List> buildPdf({
    required String markingKeyTitle,
    required String subjectName,
    required HomeAssignmentResult result,
  }) async {
    final byNumber = {for (final k in result.markingKey) k.number: k.expectedAnswerOrKeywords};
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) => [
          pw.Text(subjectName, style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
          pw.SizedBox(height: 8),
          pw.Text(markingKeyTitle, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text('For: ${result.title}', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
          pw.SizedBox(height: 16),
          for (final q in result.questions)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 12),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.SizedBox(width: 28, child: pw.Text('${q.number}.', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                      pw.Expanded(child: pw.Text(q.text)),
                      pw.SizedBox(width: 50, child: pw.Text('[${q.maxMarks.toStringAsFixed(q.maxMarks == q.maxMarks.roundToDouble() ? 0 : 1)}]', textAlign: pw.TextAlign.right)),
                    ],
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(left: 28, top: 2),
                    child: pw.Text(
                      byNumber[q.number]?.trim().isNotEmpty == true ? byNumber[q.number]! : '(no expected answer given)',
                      style: pw.TextStyle(fontSize: 10.5, fontStyle: pw.FontStyle.italic, color: PdfColors.grey800),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return doc.save();
  }
}
