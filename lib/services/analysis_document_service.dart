import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/grading_scale.dart';
import '../models/marking_scheme.dart';
import '../models/marking_script.dart';

/// One row of the results list, already computed — kept separate from
/// [MarkingScript] so this service doesn't need to re-derive percentages
/// or re-run [classify] itself; MarkingAnalysisScreen already has both.
class AnalysisResultRow {
  final MarkingScript script;
  final double percent;
  final GradeBand band;

  const AnalysisResultRow({required this.script, required this.percent, required this.band});
}

/// AI-Assisted Marking, Analysis — renders the performance analysis
/// MarkingAnalysisScreen shows on-device as an actual PDF or Word
/// document ("this file which will be produced"), not just an on-screen
/// view. Adds standard descriptive statistics (mean, pass rate, range)
/// alongside the gender x grade-band table and results list, since a
/// real school performance-analysis report conventionally includes them
/// — "best practices" per the feature's own request, not something
/// explicitly itemized but a reasonable, well-established addition for
/// this kind of document. Entirely on-device, no network — same pattern
/// as MarksheetDocumentService (hand-built minimal OOXML for .docx, the
/// `pdf` package for .pdf).
class AnalysisDocumentService {
  String _fileBaseName(MarkingScheme scheme) {
    final safe = scheme.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return 'analysis_${safe.isEmpty ? 'scheme' : safe}';
  }

  Future<File> _writeToTempFile(String extension, List<int> bytes, MarkingScheme scheme) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_fileBaseName(scheme)}.$extension');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _fmt(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);

  /// Descriptive statistics every real performance-analysis report
  /// conventionally includes: candidate count, mean, highest/lowest, and
  /// a pass rate (percentage NOT in the bottom/fail band, whichever
  /// system is in use — grade 9 for British, F for American).
  Map<String, String> _summaryStats(List<AnalysisResultRow> rows, GradingSystem system) {
    if (rows.isEmpty) return {};
    final percents = [for (final r in rows) r.percent];
    final mean = percents.reduce((a, b) => a + b) / percents.length;
    final highest = percents.reduce((a, b) => a > b ? a : b);
    final lowest = percents.reduce((a, b) => a < b ? a : b);
    final failBand = gradeBandsFor(system).last; // lowest band is always last
    final failCount = rows.where((r) => r.band.fullLabel == failBand.fullLabel).length;
    final passRate = ((rows.length - failCount) / rows.length) * 100;
    return {
      'Candidates': '${rows.length}',
      'Mean score': '${_fmt(mean)}%',
      'Highest score': '${_fmt(highest)}%',
      'Lowest score': '${_fmt(lowest)}%',
      'Pass rate': '${_fmt(passRate)}% (${rows.length - failCount} of ${rows.length})',
    };
  }

  // ---------------------------------------------------------------------
  // PDF
  // ---------------------------------------------------------------------

  Future<File> generatePdf({
    required MarkingScheme scheme,
    required List<AnalysisResultRow> rows,
    required GradingSystem system,
    required Map<CandidateGender, Map<String, int>> counts,
  }) async {
    final bands = gradeBandsFor(system);
    final stats = _summaryStats(rows, system);
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        header: (context) => context.pageNumber == 1
            ? pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('PERFORMANCE ANALYSIS', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    '${scheme.title}  ·  ${scheme.subjectName}  ·  ${scheme.gradeName}  ·  ${system.label} grading',
                    style: const pw.TextStyle(fontSize: 11),
                  ),
                  pw.SizedBox(height: 10),
                ],
              )
            : pw.SizedBox(),
        build: (context) => [
          pw.Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [for (final entry in stats.entries) _pdfStat(entry.key, entry.value)],
          ),
          pw.SizedBox(height: 14),
          pw.Text('Results by gender and grade', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(width: 0.5),
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  _pdfCell('', bold: true),
                  for (final band in bands) _pdfCell(band.fullLabel, bold: true),
                  _pdfCell('Total', bold: true),
                ],
              ),
              for (final gender in CandidateGender.values)
                pw.TableRow(children: [
                  _pdfCell(gender.label, bold: true),
                  for (final band in bands) _pdfCell('${counts[gender]![band.fullLabel] ?? 0}'),
                  _pdfCell('${counts[gender]!.values.fold(0, (a, b) => a + b)}', bold: true),
                ]),
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey100),
                children: [
                  _pdfCell('All', bold: true),
                  for (final band in bands)
                    _pdfCell(
                      '${CandidateGender.values.fold(0, (sum, g) => sum + (counts[g]![band.fullLabel] ?? 0))}',
                      bold: true,
                    ),
                  _pdfCell('${rows.length}', bold: true),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          pw.Text('Full results list', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(0.6),
              1: pw.FlexColumnWidth(2.2),
              2: pw.FlexColumnWidth(1),
              3: pw.FlexColumnWidth(1),
              4: pw.FlexColumnWidth(1.6),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  _pdfCell('#', bold: true),
                  _pdfCell('Student', bold: true),
                  _pdfCell('Gender', bold: true),
                  _pdfCell('Score', bold: true),
                  _pdfCell('Grade', bold: true),
                ],
              ),
              for (final row in rows)
                pw.TableRow(children: [
                  _pdfCell('${row.script.scriptNumber}'),
                  _pdfCell('${row.script.firstName}\n${row.script.surname}'),
                  _pdfCell(row.script.gender.label),
                  _pdfCell('${_fmt(row.percent)}%'),
                  _pdfCell(row.band.fullLabel),
                ]),
            ],
          ),
        ],
      ),
    );

    return _writeToTempFile('pdf', await doc.save(), scheme);
  }

  pw.Widget _pdfStat(String label, String value) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5), borderRadius: pw.BorderRadius.circular(4)),
        child: pw.Text('$label: $value', style: const pw.TextStyle(fontSize: 10)),
      );

  pw.Widget _pdfCell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : null)),
      );

  // ---------------------------------------------------------------------
  // DOCX — hand-built minimal OOXML package, same approach as
  // MarksheetDocumentService.generateDocx.
  // ---------------------------------------------------------------------

  Future<File> generateDocx({
    required MarkingScheme scheme,
    required List<AnalysisResultRow> rows,
    required GradingSystem system,
    required Map<CandidateGender, Map<String, int>> counts,
  }) async {
    final archive = Archive();
    void addXml(String name, String xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    addXml('[Content_Types].xml', _contentTypesXml);
    addXml('_rels/.rels', _packageRelsXml);
    addXml('word/_rels/document.xml.rels', _documentRelsXml);
    addXml('docProps/core.xml', _corePropsXml);
    addXml('docProps/app.xml', _appPropsXml);
    addXml('word/document.xml', _buildDocumentXml(scheme, rows, system, counts));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile('docx', zipped, scheme);
  }

  String _buildDocumentXml(
    MarkingScheme scheme,
    List<AnalysisResultRow> rows,
    GradingSystem system,
    Map<CandidateGender, Map<String, int>> counts,
  ) {
    final bands = gradeBandsFor(system);
    final stats = _summaryStats(rows, system);
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_docxHeading('PERFORMANCE ANALYSIS', size: 32, center: true));
    buffer.write(_docxParagraph(
      '${scheme.title}  ·  ${scheme.subjectName}  ·  ${scheme.gradeName}  ·  ${system.label} grading',
      bold: true,
    ));
    for (final entry in stats.entries) {
      buffer.write(_docxLabeledLine(entry.key, entry.value));
    }
    buffer.write(_docxHeading('Results by gender and grade', size: 26));
    buffer.write(_docxCountsTable(bands, counts, rows.length));
    buffer.write(_docxHeading('Full results list', size: 26));
    buffer.write(_docxResultsTable(rows));
    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _docxCountsTable(List<GradeBand> bands, Map<CandidateGender, Map<String, int>> counts, int total) {
    final buffer = StringBuffer(_docxTableOpen());
    buffer.write(_docxTableRow(['', for (final b in bands) b.fullLabel, 'Total'], bold: true));
    for (final gender in CandidateGender.values) {
      buffer.write(_docxTableRow([
        gender.label,
        for (final b in bands) '${counts[gender]![b.fullLabel] ?? 0}',
        '${counts[gender]!.values.fold(0, (a, b) => a + b)}',
      ]));
    }
    buffer.write(_docxTableRow([
      'All',
      for (final b in bands) '${CandidateGender.values.fold(0, (sum, g) => sum + (counts[g]![b.fullLabel] ?? 0))}',
      '$total',
    ], bold: true));
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  String _docxResultsTable(List<AnalysisResultRow> rows) {
    final buffer = StringBuffer(_docxTableOpen());
    buffer.write(_docxTableRow(['#', 'First Name', 'Surname', 'Gender', 'Score', 'Grade'], bold: true));
    for (final row in rows) {
      buffer.write(_docxTableRow([
        '${row.script.scriptNumber}',
        row.script.firstName,
        row.script.surname,
        row.script.gender.label,
        '${_fmt(row.percent)}%',
        row.band.fullLabel,
      ]));
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  String _docxTableOpen() =>
      '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
      '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '</w:tblBorders></w:tblPr>';

  String _docxHeading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="200" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _docxParagraph(String text, {bool bold = false}) {
    final rPr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
    return '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr>'
        '<w:r>$rPr<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _docxLabeledLine(String label, String value) =>
      '<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(label)}: </w:t></w:r>'
      '<w:r><w:t xml:space="preserve">${_xmlEscape(value)}</w:t></w:r></w:p>';

  String _docxTableRow(List<String> cells, {bool bold = false}) {
    final buffer = StringBuffer('<w:tr>');
    for (final cell in cells) {
      final rPr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
      buffer.write(
        '<w:tc><w:tcPr><w:tcW w:w="1400" w:type="dxa"/></w:tcPr>'
        '<w:p><w:r>$rPr<w:t xml:space="preserve">${_xmlEscape(cell)}</w:t></w:r></w:p></w:tc>',
      );
    }
    buffer.write('</w:tr>');
    return buffer.toString();
  }

  String _xmlEscape(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static const _contentTypesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/docProps/core.xml" '
      'ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      '<Override PartName="/docProps/app.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
      '</Types>';

  static const _packageRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
      'Target="word/document.xml"/>'
      '<Relationship Id="rId2" '
      'Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" '
      'Target="docProps/core.xml"/>'
      '<Relationship Id="rId3" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" '
      'Target="docProps/app.xml"/>'
      '</Relationships>';

  static const _documentRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>';

  static const _corePropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties '
      'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>Performance Analysis</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';
}
