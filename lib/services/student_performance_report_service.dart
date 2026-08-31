import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';

/// AI-Assisted Marking — a single student's performance report, shareable
/// as its own PDF right after a script is marked (2026-08-31). Distinct
/// from the class-wide Marksheet and Performance Analysis exports: this
/// is one candidate's own result — final percentage, per-question
/// breakdown, and the AI's observations — meant to be handed to that one
/// student/parent, not the whole class. Entirely on-device, no network —
/// same `pdf` package pattern as every other document service here.
class StudentPerformanceReportService {
  String _fileBaseName(MarkingScript script) {
    final safe = '${script.firstName}_${script.surname}'
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return 'report_${safe.isEmpty ? 'student' : safe}';
  }

  String _fmt(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);

  Future<File> generatePdf(MarkingScript script, MarkingScheme? scheme) async {
    final answers = script.gradedAnswers ?? const <GradedAnswer>[];
    final totalAwarded = script.totalAwarded ?? 0;
    final totalPossible = script.totalPossible ?? 0;
    final percent = totalPossible == 0 ? 0.0 : (totalAwarded / totalPossible) * 100;

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (context) => context.pageNumber == 1
            ? pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('STUDENT PERFORMANCE REPORT', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    scheme == null
                        ? '${script.subjectName}  ·  ${script.gradeName}'
                        : '${scheme.title}  ·  ${script.subjectName}  ·  ${script.gradeName}',
                    style: const pw.TextStyle(fontSize: 11),
                  ),
                  pw.SizedBox(height: 12),
                ],
              )
            : pw.SizedBox(),
        build: (context) => [
          _studentInfoBlock(script),
          pw.SizedBox(height: 14),
          _finalResultBlock(percent, totalAwarded, totalPossible),
          pw.SizedBox(height: 16),
          if (answers.isNotEmpty) ...[
            pw.Text('Question breakdown', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            _breakdownTable(answers),
            pw.SizedBox(height: 16),
          ],
          if (script.observations case final obs? when obs.isNotEmpty) ...[
            pw.Text('AI observations', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            // pw.Bullet, not a literal '•' character — see
            // MinutesDocumentService's identical fix (2026-08-31) for why:
            // it draws its marker as a real shape, not a font glyph, so it
            // can't render as a "missing glyph" box on any device.
            for (final o in obs) pw.Bullet(text: o, style: const pw.TextStyle(fontSize: 10)),
          ],
        ],
      ),
    );

    return _writeToTempFile('pdf', await doc.save(), script);
  }

  pw.Widget _studentInfoBlock(MarkingScript script) => pw.Table(
        columnWidths: const {0: pw.FlexColumnWidth(1), 1: pw.FlexColumnWidth(1)},
        children: [
          pw.TableRow(children: [
            _infoLine('Student', script.fullName),
            _infoLine('Gender', script.gender.label),
          ]),
          pw.TableRow(children: [
            _infoLine('Student ID', script.studentIdNumber ?? '—'),
            _infoLine('Class / Level', script.classLevel.isEmpty ? '—' : script.classLevel),
          ]),
        ],
      );

  pw.Widget _infoLine(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4, right: 8),
        child: pw.RichText(
          text: pw.TextSpan(
            children: [
              pw.TextSpan(text: '$label: ', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.TextSpan(text: value, style: const pw.TextStyle(fontSize: 10)),
            ],
          ),
        ),
      );

  /// The headline number is the percentage — see MarkingReviewScreen and
  /// MarksheetDocumentService for the same "percentage is the recorded
  /// final result" rule applied here too. Raw marks shown underneath as
  /// supporting detail, not the primary figure.
  pw.Widget _finalResultBlock(double percent, double awarded, double possible) => pw.Container(
        padding: const pw.EdgeInsets.all(14),
        decoration: pw.BoxDecoration(border: pw.Border.all(width: 1), borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Final Result', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text('${_fmt(percent)}%', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
                pw.Text('${_fmt(awarded)} of ${_fmt(possible)} marks', style: const pw.TextStyle(fontSize: 9)),
              ],
            ),
          ],
        ),
      );

  pw.Widget _breakdownTable(List<GradedAnswer> answers) => pw.Table(
        border: pw.TableBorder.all(width: 0.5),
        columnWidths: const {
          0: pw.FlexColumnWidth(1.4),
          1: pw.FlexColumnWidth(1),
          2: pw.FlexColumnWidth(2.6),
        },
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey300),
            children: [
              _pdfCell('Question', bold: true),
              _pdfCell('Marks', bold: true),
              _pdfCell('AI Confidence', bold: true),
            ],
          ),
          for (final a in answers)
            pw.TableRow(children: [
              _pdfCell(a.questionLabel),
              _pdfCell('${_fmt(a.marksAwarded)} / ${_fmt(a.maxMarks)}'),
              _pdfCell(a.confidence.label),
            ]),
        ],
      );

  pw.Widget _pdfCell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Text(text, style: pw.TextStyle(fontSize: 9.5, fontWeight: bold ? pw.FontWeight.bold : null)),
      );

  Future<File> _writeToTempFile(String extension, List<int> bytes, MarkingScript script) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_fileBaseName(script)}.$extension');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}
