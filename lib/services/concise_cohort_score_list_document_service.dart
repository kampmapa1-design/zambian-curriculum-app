import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'concise_score_calculator.dart';

/// One row of a Concise Marking cohort score list.
class ConciseCohortEntry {
  final String candidateName;
  final ConciseScore score;

  /// True when this candidate's script was never actually marked in the
  /// session (added to the list but skipped) — shown as "not marked"
  /// rather than a fake zero.
  final bool marked;

  const ConciseCohortEntry({
    required this.candidateName,
    required this.score,
    this.marked = true,
  });
}

/// "When it marks any list or cohort... generate an editable word document
/// listing names of candidates and their scores... sharable in either word
/// or pdf options" (explicit request, 2026-09-10). The .docx is a
/// hand-built minimal OOXML package, same approach and boilerplate as
/// MarksheetDocumentService — no docx package dependency.
class ConciseCohortScoreListDocumentService {
  String _fileBase(String cohortTitle) {
    final safe = cohortTitle.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return 'concise_scores_${safe.isEmpty ? 'cohort' : safe}';
  }

  Future<File> _write(String cohortTitle, String ext, List<int> bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, '${_fileBase(cohortTitle)}.$ext'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _fmt(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);

  String _scoreText(ConciseCohortEntry e) =>
      e.marked ? '${_fmt(e.score.percentage.clamp(0, 100))} / 100' : 'not marked';

  String _rawText(ConciseCohortEntry e) => e.marked ? e.score.rawFractionLabel : '-';

  List<ConciseCohortEntry> _ordered(List<ConciseCohortEntry> entries) {
    final list = [...entries];
    list.sort((a, b) => a.candidateName.toLowerCase().compareTo(b.candidateName.toLowerCase()));
    return list;
  }

  // -------------------------------------------------------------------
  // PDF
  // -------------------------------------------------------------------
  Future<File> generatePdf({
    required String cohortTitle,
    String? subjectName,
    required List<ConciseCohortEntry> entries,
  }) async {
    final ordered = _ordered(entries);
    final marked = ordered.where((e) => e.marked).toList();
    final classAvg = marked.isEmpty
        ? null
        : marked.fold<double>(0, (s, e) => s + e.score.percentage.clamp(0, 100)) / marked.length;

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(level: 0, text: _pdfSafe('CONCISE MARKING - COHORT SCORES')),
          pw.Text(_pdfSafe(cohortTitle), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          if (subjectName != null && subjectName.trim().isNotEmpty)
            pw.Text(_pdfSafe(subjectName), style: const pw.TextStyle(fontSize: 11)),
          pw.SizedBox(height: 10),
          pw.Table(
            border: pw.TableBorder.all(width: 0.5, color: PdfColors.grey500),
            columnWidths: {
              0: const pw.FlexColumnWidth(0.6),
              1: const pw.FlexColumnWidth(3),
              2: const pw.FlexColumnWidth(1.4),
              3: const pw.FlexColumnWidth(1.4),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  _cell('#', bold: true),
                  _cell('Candidate', bold: true),
                  _cell('Score', bold: true),
                  _cell('Raw marks', bold: true),
                ],
              ),
              for (var i = 0; i < ordered.length; i++)
                pw.TableRow(children: [
                  _cell('${i + 1}'),
                  _cell(_pdfSafe(ordered[i].candidateName.isEmpty ? '(no name)' : ordered[i].candidateName)),
                  _cell(_scoreText(ordered[i]), bold: true),
                  _cell(_rawText(ordered[i])),
                ]),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Text(
            '${marked.length} candidate(s) marked'
            '${ordered.length - marked.length > 0 ? ' - ${ordered.length - marked.length} added but not marked' : ''}'
            '${classAvg != null ? '  ·  class average ${classAvg.toStringAsFixed(1)}%' : ''}',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey800),
          ),
        ],
      ),
    );
    return _write(cohortTitle, 'pdf', await doc.save());
  }

  pw.Widget _cell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : null)),
      );

  String _pdfSafe(String s) => s.replaceAll('—', '-').replaceAll('–', '-');

  // -------------------------------------------------------------------
  // DOCX — hand-built minimal OOXML, same pattern as MarksheetDocumentService
  // -------------------------------------------------------------------
  Future<File> generateDocx({
    required String cohortTitle,
    String? subjectName,
    required List<ConciseCohortEntry> entries,
  }) async {
    final ordered = _ordered(entries);
    final marked = ordered.where((e) => e.marked).toList();

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
    addXml('word/document.xml', _buildDocumentXml(cohortTitle, subjectName, ordered, marked.length));

    return _write(cohortTitle, 'docx', ZipEncoder().encode(archive));
  }

  String _buildDocumentXml(String cohortTitle, String? subjectName, List<ConciseCohortEntry> ordered, int markedCount) {
    final b = StringBuffer();
    b.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>',
    );
    b.write(_heading('CONCISE MARKING - COHORT SCORES', size: 32, center: true));
    b.write(_para(cohortTitle, bold: true));
    if (subjectName != null && subjectName.trim().isNotEmpty) b.write(_para(subjectName));
    b.write('<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
        '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
        '</w:tblBorders></w:tblPr>');
    b.write(_row(['#', 'Candidate', 'Score', 'Raw marks'], bold: true));
    for (var i = 0; i < ordered.length; i++) {
      b.write(_row([
        '${i + 1}',
        ordered[i].candidateName.isEmpty ? '(no name)' : ordered[i].candidateName,
        _scoreText(ordered[i]),
        _rawText(ordered[i]),
      ]));
    }
    b.write('</w:tbl>');
    b.write(_para('$markedCount candidate(s) marked'
        '${ordered.length - markedCount > 0 ? ' - ${ordered.length - markedCount} added but not marked' : ''}'));
    b.write('<w:sectPr/></w:body></w:document>');
    return b.toString();
  }

  String _heading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="200" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';
  }

  String _para(String text, {bool bold = false}) {
    final rPr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
    return '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr>'
        '<w:r>$rPr<w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';
  }

  String _row(List<String> cells, {bool bold = false}) {
    final b = StringBuffer('<w:tr>');
    for (final cell in cells) {
      final rPr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
      b.write('<w:tc><w:tcPr><w:tcW w:w="1800" w:type="dxa"/></w:tcPr>'
          '<w:p><w:r>$rPr<w:t xml:space="preserve">${_esc(cell)}</w:t></w:r></w:p></w:tc>');
    }
    b.write('</w:tr>');
    return b.toString();
  }

  String _esc(String s) => s
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
      '<dc:title>Concise Marking Cohort Scores</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';
}
