import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';

/// AI-Assisted Marking, Stage 7 — aggregates every fully-reviewed script
/// from one marking scheme into a class marksheet (per student, per
/// question, total) and renders it as PDF, Word (.docx), or CSV (genuinely
/// Excel-openable — a hand-built .xlsx binary carries real corruption
/// risk for little benefit over CSV, which every spreadsheet app already
/// opens natively). Entirely on-device, no network. The .docx writer is a
/// hand-built minimal OOXML package, same approach and same boilerplate
/// as LessonPlanDocumentService/SchemeOfWorkDocumentService — no
/// docx-authoring package dependency needed.
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
  /// review yet, so it isn't a confirmed mark. Alphabetical by surname
  /// (then first name) by default — the standard convention for a class
  /// list — unless [MarkingScheme.preserveScriptOrder] says otherwise
  /// (an explicit "keep list order" answer at class-list-import time), in
  /// which case scriptNumber (capture/import order) is kept instead.
  List<MarkingScript> _confirmedScripts(MarkingScheme scheme, List<MarkingScript> scripts) {
    final confirmed = scripts.where((s) => s.status == MarkingScriptStatus.reviewed && s.gradedAnswers != null).toList();
    if (scheme.preserveScriptOrder) {
      confirmed.sort((a, b) => a.scriptNumber.compareTo(b.scriptNumber));
    } else {
      confirmed.sort((a, b) {
        final bySurname = a.surname.toLowerCase().compareTo(b.surname.toLowerCase());
        return bySurname != 0 ? bySurname : a.firstName.toLowerCase().compareTo(b.firstName.toLowerCase());
      });
    }
    return confirmed;
  }

  Future<File> generatePdf(MarkingScheme scheme, List<MarkingScript> scripts) async {
    final confirmed = _confirmedScripts(scheme, scripts);
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
              1: const pw.FlexColumnWidth(0.8),
              2: const pw.FlexColumnWidth(1.2),
              for (var i = 0; i < scheme.questions.length; i++) i + 3: const pw.FlexColumnWidth(1),
              scheme.questions.length + 3: const pw.FlexColumnWidth(1.2),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  _pdfCell('Student', bold: true),
                  _pdfCell('Gender', bold: true),
                  _pdfCell('ID', bold: true),
                  for (final q in scheme.questions) _pdfCell('${q.label}\n(${_fmt(q.maxMarks)})', bold: true),
                  _pdfCell('Total\n(${_fmt(scheme.totalMarks)})', bold: true),
                ],
              ),
              for (final script in confirmed)
                pw.TableRow(
                  children: [
                    // First name on top, surname below — same order used
                    // everywhere else in this feature.
                    _pdfCell('${script.firstName}\n${script.surname}'),
                    _pdfCell(script.gender.label),
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

  // ---------------------------------------------------------------------
  // DOCX — hand-built minimal OOXML package, same approach as
  // LessonPlanDocumentService.generateDocx: [Content_Types].xml,
  // _rels/.rels, word/document.xml (+ its rels and docProps).
  // ---------------------------------------------------------------------

  Future<File> generateDocx(MarkingScheme scheme, List<MarkingScript> scripts) async {
    final confirmed = _confirmedScripts(scheme, scripts);
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
    addXml('word/document.xml', _buildDocumentXml(scheme, confirmed, scripts.length - confirmed.length));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile('docx', zipped, scheme);
  }

  String _buildDocumentXml(MarkingScheme scheme, List<MarkingScript> confirmed, int excludedCount) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_docxHeading('CLASS MARKSHEET', size: 32, center: true));
    buffer.write(_docxParagraph('${scheme.title}  ·  ${scheme.subjectName}  ·  ${scheme.gradeName}', bold: true));
    buffer.write(_docxMarksheetTable(scheme, confirmed));
    buffer.write(_docxParagraph(
      '${confirmed.length} student(s) reviewed and confirmed'
      '${excludedCount > 0 ? ' · $excludedCount not yet reviewed (excluded)' : ''}',
    ));
    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _docxMarksheetTable(MarkingScheme scheme, List<MarkingScript> confirmed) {
    final buffer = StringBuffer(
      '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
      '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '</w:tblBorders></w:tblPr>',
    );
    buffer.write(_docxTableRow([
      'First Name',
      'Surname',
      'Gender',
      'ID',
      for (final q in scheme.questions) '${q.label} (${_fmt(q.maxMarks)})',
      'Total (${_fmt(scheme.totalMarks)})',
    ], bold: true));
    for (final script in confirmed) {
      buffer.write(_docxTableRow([
        script.firstName,
        script.surname,
        script.gender.label,
        script.studentIdNumber ?? '—',
        for (final q in scheme.questions)
          _fmt(script.gradedAnswers!.where((a) => a.questionLabel == q.label).map((a) => a.marksAwarded).firstOrNull ?? 0),
        _fmt(script.totalAwarded ?? 0),
      ]));
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

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
      '<dc:title>Class Marksheet</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';

  /// CSV — opens natively in Excel, Google Sheets, or any spreadsheet
  /// app, with none of the binary-format risk of hand-building a real
  /// .xlsx file.
  Future<File> generateCsv(MarkingScheme scheme, List<MarkingScript> scripts) async {
    final confirmed = _confirmedScripts(scheme, scripts);
    final buffer = StringBuffer();

    String csvField(String value) {
      if (value.contains(',') || value.contains('"') || value.contains('\n')) {
        return '"${value.replaceAll('"', '""')}"';
      }
      return value;
    }

    final headers = [
      'First Name',
      'Surname',
      'Gender',
      'ID',
      for (final q in scheme.questions) '${q.label} (of ${_fmt(q.maxMarks)})',
      'Total (of ${_fmt(scheme.totalMarks)})',
      'AI Observations',
    ];
    buffer.writeln(headers.map(csvField).join(','));

    for (final script in confirmed) {
      final row = [
        script.firstName,
        script.surname,
        script.gender.label,
        script.studentIdNumber ?? '',
        for (final q in scheme.questions)
          _fmt(script.gradedAnswers!.where((a) => a.questionLabel == q.label).map((a) => a.marksAwarded).firstOrNull ?? 0),
        _fmt(script.totalAwarded ?? 0),
        (script.observations ?? const []).join(' | '),
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
