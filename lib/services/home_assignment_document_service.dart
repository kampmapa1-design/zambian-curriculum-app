import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/home_assignment.dart';

/// Home Assignment epic, Stage 7 — builds the plain, printable PDF sent
/// as an email attachment (see `sendHomeAssignmentToClass`). Simple by
/// design: title, instructions, then every question in order — matches
/// the same "working document, not a chat reply" plain-text discipline
/// the generation prompt itself already enforces.
class HomeAssignmentDocumentService {
  Future<Uint8List> buildPdf({required String schoolName, required String className, required HomeAssignmentResult result}) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) => [
          pw.Text(schoolName, style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
          pw.Text('$className — Home Assignment', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
          pw.SizedBox(height: 8),
          pw.Text(result.title, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          if (result.instructions.trim().isNotEmpty) ...[
            pw.SizedBox(height: 8),
            pw.Text(result.instructions, style: const pw.TextStyle(fontSize: 11)),
          ],
          pw.SizedBox(height: 16),
          for (final q in result.questions)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 10),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(width: 28, child: pw.Text('${q.number}.', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(child: pw.Text(q.text)),
                  pw.SizedBox(width: 50, child: pw.Text('[${q.maxMarks.toStringAsFixed(q.maxMarks == q.maxMarks.roundToDouble() ? 0 : 1)}]', textAlign: pw.TextAlign.right)),
                ],
              ),
            ),
        ],
      ),
    );
    return doc.save();
  }
}
