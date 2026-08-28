import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';

/// AI-Assisted Marking, Stage 7 — aggregates every fully-reviewed script
/// from one marking scheme into a class marksheet (per student, per
/// question, total) and renders it as PDF or CSV (genuinely
/// Excel-openable — a hand-built .xlsx binary carries real corruption
/// risk for little benefit over CSV, which every spreadsheet app already
/// opens natively). Entirely on-device, no network.
class MarksheetDocumentService {
  String _fileBaseName(MarkingScheme scheme) {
    final safe = scheme.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return 'marksheet_${safe.isEmpty ? 'scheme' : safe}';
  }

  Future<File> _writeToTempFile(String extension, List<int> bytes, MarkingScheme scheme) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_fileBaseName(scheme)}.$extension');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Only [MarkingScriptStatus.reviewed] scripts count — anything still
  /// [MarkingScriptStatus.graded] hasn't cleared Stage 6's mandatory
  /// review yet, so it isn't a confirmed mark.
  List<MarkingScript> _confirmedScripts(List<MarkingScript> scripts) =>
      scripts.where((s) => s.status == MarkingScriptStatus.reviewed && s.gradedAnswers != null).toList()
        ..sort((a, b) => a.scriptNumber.compareTo(b.scriptNumber));

  Future<File> generatePdf(MarkingScheme scheme, List<MarkingScript> scripts) async {
    final confirmed = _confirmedScripts(scripts);
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        header: (context) => context.pageNumber == 1
            ? pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('CLASS MARKSHEET', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  pw.Text('${scheme.title}  ·  ${scheme.subjectName}  ·  ${scheme.gradeName}',
                      style: const pw.TextStyle(fontSize: 11)),
                  pw.SizedBox(height: 10),
                ],
              )
            : pw.SizedBox(),
        build: (context) => [
          pw.Table(
            border: pw.TableBorder.all(width: 0.5),
            columnWidths: {
              0: const pw.FlexColumnWidth(2.2),
              1: const pw.FlexColumnWidth(1.2),
              for (var i = 0; i < scheme.questions.length; i++) i + 2: const pw.FlexColumnWidth(1),
              scheme.questions.length + 2: const pw.FlexColumnWidth(1.2),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  _pdfCell('Student', bold: true),
                  _pdfCell('ID', bold: true),
                  for (final q in scheme.questions) _pdfCell('${q.label}\n(${_fmt(q.maxMarks)})', bold: true),
                  _pdfCell('Total\n(${_fmt(scheme.totalMarks)})', bold: true),
                ],
              ),
              for (final script in confirmed)
                pw.TableRow(
                  children: [
                    _pdfCell(script.studentName),
                    _pdfCell(script.studentIdNumber ?? '—'),
                    for (final q in scheme.questions)
                      _pdfCell(_fmt(
                        script.gradedAnswers!.where((a) => a.questionLabel == q.label).map((a) => a.marksAwarded).firstOrNull ?? 0,
                      )),
                    _pdfCell(_fmt(script.totalAwarded ?? 0), bold: true),
                  ],
                ),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Text(
            '${confirmed.length} student(s) reviewed and confirmed'
            '${scripts.length - confirmed.length > 0 ? ' · ${scripts.length - confirmed.length} not yet reviewed (excluded)' : ''}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
        ],
      ),
    );

    return _writeToTempFile('pdf', await doc.save(), scheme);
  }

  pw.Widget _pdfCell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : null)),
      );

  String _fmt(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);

  /// CSV — opens natively in Excel, Google Sheets, or any spreadsheet
  /// app, with none of the binary-format risk of hand-building a real
  /// .xlsx file.
  Future<File> generateCsv(MarkingScheme scheme, List<MarkingScript> scripts) async {
    final confirmed = _confirmedScripts(scripts);
    final buffer = StringBuffer();

    String csvField(String value) {
      if (value.contains(',') || value.contains('"') || value.contains('\n')) {
        return '"${value.replaceAll('"', '""')}"';
      }
      return value;
    }

    final headers = [
      'Student',
      'ID',
      for (final q in scheme.questions) '${q.label} (of ${_fmt(q.maxMarks)})',
      'Total (of ${_fmt(scheme.totalMarks)})',
    ];
    buffer.writeln(headers.map(csvField).join(','));

    for (final script in confirmed) {
      final row = [
        script.studentName,
        script.studentIdNumber ?? '',
        for (final q in scheme.questions)
          _fmt(script.gradedAnswers!.where((a) => a.questionLabel == q.label).map((a) => a.marksAwarded).firstOrNull ?? 0),
        _fmt(script.totalAwarded ?? 0),
      ];
      buffer.writeln(row.map(csvField).join(','));
    }

    // A UTF-8 BOM so Excel (which otherwise guesses the wrong encoding
    // for anything beyond plain ASCII) opens this correctly. Actual UTF-8
    // encoding matters here, not just the BOM — `.codeUnits` would give
    // UTF-16 code units instead, silently corrupting any name with a
    // character outside plain ASCII.
    final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(buffer.toString())];
    return _writeToTempFile('csv', bytes, scheme);
  }
}
