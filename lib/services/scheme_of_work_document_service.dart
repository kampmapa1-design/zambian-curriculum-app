import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/scheme_of_work_document.dart';

/// Identifies which subject/grade/curriculum a scheme-of-work document is
/// for — display-only context, not stored in the draft itself.
class SchemeOfWorkDocumentContext {
  final String subjectName;
  final String gradeName;
  final String curriculumName;
  final String termLabel;

  const SchemeOfWorkDocumentContext({
    required this.subjectName,
    required this.gradeName,
    required this.curriculumName,
    required this.termLabel,
  });
}

const _columnHeaders = [
  'Week',
  'Topic / Sub-topic',
  'Prescribed Competences',
  'Specific Competences',
  'Content / Concept',
  'Learning Activities',
  'Expected Standard',
  'Strategies / Methods',
  'Assessments',
  'Material / Resources',
  'References',
];

List<String> _rowCells(SchemeOfWorkRowDraft row) => [
      '${row.entry.weekNumber}',
      row.entry.title,
      row.prescribedCompetences,
      row.entry.competencies.map((c) => c.description).join('\n'),
      row.contentConcept,
      row.entry.objectives.map((o) => o.description).join('\n'),
      row.expectedStandard,
      row.strategiesMethods,
      row.assessments,
      row.materialResources,
      row.references,
    ];

/// Renders a [SchemeOfWorkDocumentDraft] as a PDF or Word (.docx) file,
/// entirely on-device — no network, no server round trip. Mirrors
/// [LessonPlanDocumentService]'s approach: the `pdf` package for PDF, a
/// small hand-built OOXML writer for DOCX (no template file, no extra
/// package dependency).
class SchemeOfWorkDocumentService {
  String _fileBaseName(SchemeOfWorkDocumentContext context) {
    final safeSubject =
        context.subjectName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safeSubject.isEmpty ? 'scheme_of_work' : 'scheme_of_work_$safeSubject';
  }

  Future<File> _writeToTempFile(String extension, List<int> bytes, SchemeOfWorkDocumentContext context) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_fileBaseName(context)}.$extension');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  // ---------------------------------------------------------------------
  // PDF — landscape, since the CDC layout has 11 columns.
  // ---------------------------------------------------------------------

  Future<File> generatePdf(SchemeOfWorkDocumentContext context, SchemeOfWorkDocumentDraft draft) async {
    final doc = pw.Document();
    final header = draft.header;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        build: (pdfContext) => [
          pw.Center(
            child: pw.Text('SCHEME OF WORK', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(height: 10),
          _pdfLabeledLine('Name of School', header.schoolName),
          _pdfLabeledLine('Name of Teacher', header.teacherName),
          _pdfLabeledLine('Level', context.gradeName),
          _pdfLabeledLine('Subject', context.subjectName),
          _pdfLabeledLine('Curriculum', context.curriculumName),
          _pdfLabeledLine('Term', context.termLabel),
          _pdfLabeledLine('Year', header.year),
          if (header.curriculumPhilosophyAndGoals.trim().isNotEmpty) ...[
            pw.SizedBox(height: 6),
            pw.Text('Curriculum Philosophy and Goals',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
            pw.Text(header.curriculumPhilosophyAndGoals, style: const pw.TextStyle(fontSize: 9.5)),
          ],
          pw.SizedBox(height: 12),
          pw.Table(
            border: pw.TableBorder.all(width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(0.5),
              1: pw.FlexColumnWidth(1.6),
              2: pw.FlexColumnWidth(1.3),
              3: pw.FlexColumnWidth(1.6),
              4: pw.FlexColumnWidth(1.3),
              5: pw.FlexColumnWidth(1.8),
              6: pw.FlexColumnWidth(1.3),
              7: pw.FlexColumnWidth(1.2),
              8: pw.FlexColumnWidth(1.2),
              9: pw.FlexColumnWidth(1.3),
              10: pw.FlexColumnWidth(1.2),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [for (final h in _columnHeaders) _pdfHeaderCell(h)],
              ),
              for (final row in draft.rows)
                pw.TableRow(children: [for (final cell in _rowCells(row)) _pdfCell(cell)]),
            ],
          ),
        ],
      ),
    );

    final bytes = await doc.save();
    return _writeToTempFile('pdf', bytes, context);
  }

  pw.Widget _pdfLabeledLine(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 2),
        child: pw.RichText(
          text: pw.TextSpan(
            children: [
              pw.TextSpan(text: '$label: ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
              pw.TextSpan(text: value, style: const pw.TextStyle(fontSize: 10)),
            ],
          ),
        ),
      );

  pw.Widget _pdfHeaderCell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(3),
        child: pw.Text(text, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7.5)),
      );

  pw.Widget _pdfCell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(3),
        child: pw.Text(text, style: const pw.TextStyle(fontSize: 7.5)),
      );

  // ---------------------------------------------------------------------
  // DOCX — hand-built minimal OOXML package, same approach as
  // LessonPlanDocumentService: Word/LibreOffice/Google Docs all accept this
  // minimal part set without needing a template .docx or an authoring
  // package dependency.
  // ---------------------------------------------------------------------

  Future<File> generateDocx(SchemeOfWorkDocumentContext context, SchemeOfWorkDocumentDraft draft) async {
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
    addXml('word/document.xml', _buildDocumentXml(context, draft));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile('docx', zipped, context);
  }

  String _buildDocumentXml(SchemeOfWorkDocumentContext context, SchemeOfWorkDocumentDraft draft) {
    final header = draft.header;
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );

    buffer.write(_docxHeading('SCHEME OF WORK', size: 32, center: true));
    buffer.write(_docxLabeledParagraph('Name of School', header.schoolName));
    buffer.write(_docxLabeledParagraph('Name of Teacher', header.teacherName));
    buffer.write(_docxLabeledParagraph('Level', context.gradeName));
    buffer.write(_docxLabeledParagraph('Subject', context.subjectName));
    buffer.write(_docxLabeledParagraph('Curriculum', context.curriculumName));
    buffer.write(_docxLabeledParagraph('Term', context.termLabel));
    buffer.write(_docxLabeledParagraph('Year', header.year));
    if (header.curriculumPhilosophyAndGoals.trim().isNotEmpty) {
      buffer.write(_docxLabeledParagraph('Curriculum Philosophy and Goals', header.curriculumPhilosophyAndGoals));
    }

    buffer.write(_docxTable(draft));

    buffer.write('<w:sectPr><w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/></w:sectPr></w:body></w:document>');
    return buffer.toString();
  }

  String _docxHeading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="200" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _docxLabeledParagraph(String label, String value) {
    return '<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>'
        '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(label)}: </w:t></w:r>'
        '<w:r><w:t xml:space="preserve">${_xmlEscape(value)}</w:t></w:r></w:p>';
  }

  String _docxTable(SchemeOfWorkDocumentDraft draft) {
    final buffer = StringBuffer();
    buffer.write(
      '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
      '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '</w:tblBorders></w:tblPr>',
    );
    buffer.write(_docxTableRow(_columnHeaders, bold: true));
    for (final row in draft.rows) {
      buffer.write(_docxTableRow(_rowCells(row)));
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  String _docxTableRow(List<String> cells, {bool bold = false}) {
    final buffer = StringBuffer('<w:tr>');
    for (final cell in cells) {
      final rPr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
      final lines = cell.isEmpty ? [''] : cell.split('\n');
      buffer.write('<w:tc><w:tcPr><w:tcW w:w="1300" w:type="dxa"/></w:tcPr>');
      for (final line in lines) {
        buffer.write('<w:p><w:r>$rPr<w:t xml:space="preserve">${_xmlEscape(line)}</w:t></w:r></w:p>');
      }
      buffer.write('</w:tc>');
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
      '<dc:title>Scheme of Work</dc:title>'
      '<dc:creator>Zambian Curriculum Companion</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Zambian Curriculum Companion</Application>'
      '</Properties>';
}
