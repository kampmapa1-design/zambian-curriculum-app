import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/lesson_plan.dart';
import '../models/marking_scheme.dart';
import 'related_marking_key_section.dart';

/// Renders a [LessonPlanDraft] against a [LessonPlanTemplate] as a PDF or a
/// Word (.docx) file, entirely on-device — no network, no server round trip.
class LessonPlanDocumentService {
  String _fileBaseName(LessonPlanDraft draft) {
    final topic = draft.value('topic').trim();
    final safeTopic = topic.isEmpty
        ? 'lesson_plan'
        : topic.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safeTopic.isEmpty ? 'lesson_plan' : safeTopic;
  }

  Future<File> _writeToTempFile(String extension, List<int> bytes, LessonPlanDraft draft) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_fileBaseName(draft)}.$extension');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  // ---------------------------------------------------------------------
  // PDF
  // ---------------------------------------------------------------------

  Future<File> generatePdf(
    LessonPlanTemplate template,
    LessonPlanDraft draft, {
    List<MarkingScheme> relatedMarkingKeys = const [],
  }) async {
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) => [
          pw.Center(
            child: pw.Text('LESSON PLAN', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(height: 16),
          // "evaluation" (Teacher's/Learners' or Lesson Evaluation) is
          // rendered after the progression table below, matching the real
          // templates this app was built from — those fields come at the
          // very bottom of the document, filled in by hand after teaching.
          for (final section in template.sections.where((s) => s.id != 'evaluation')) ...[
            if (section.id != 'header') ...[
              pw.SizedBox(height: 12),
              pw.Text(section.title, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
              pw.Divider(thickness: 0.5),
            ],
            for (final field in section.fields) _pdfField(field, draft.value(field.id)),
          ],
          pw.SizedBox(height: 14),
          pw.Text('LESSON PROGRESSION', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(1.3),
              1: pw.FlexColumnWidth(2.5),
              2: pw.FlexColumnWidth(2.2),
              3: pw.FlexColumnWidth(2),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  _pdfHeaderCell('Stage'),
                  _pdfHeaderCell("Teacher's Role"),
                  _pdfHeaderCell("Learners' Role"),
                  _pdfHeaderCell('Assessment Criteria'),
                ],
              ),
              for (final row in draft.progression)
                pw.TableRow(
                  children: [
                    _pdfCell(
                      row.durationMinutes.trim().isEmpty ? row.stage : '${row.stage}\n(${row.durationMinutes})',
                      bold: true,
                    ),
                    _pdfCell(row.teacherRole),
                    _pdfCell(row.learnersRole),
                    _pdfCell(row.assessmentCriteria),
                  ],
                ),
            ],
          ),
          for (final section in template.sections.where((s) => s.id == 'evaluation')) ...[
            pw.SizedBox(height: 12),
            pw.Text(section.title, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
            pw.Divider(thickness: 0.5),
            for (final field in section.fields) _pdfField(field, draft.value(field.id)),
          ],
          ...buildRelatedMarkingKeyPdfSection(relatedMarkingKeys),
        ],
      ),
    );

    final bytes = await doc.save();
    return _writeToTempFile('pdf', bytes, draft);
  }

  /// Renders one header/planning/evaluation field. A [blankSpaceOnPrint]
  /// field (Teacher's/Learners' Evaluation) always prints — ruled blank
  /// lines when empty, so there's physical room to handwrite a note on the
  /// printed page — rather than being silently omitted the way any other
  /// unfilled optional field is.
  pw.Widget _pdfField(LessonPlanFieldDef field, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty && !field.required && !field.blankSpaceOnPrint) {
      return pw.SizedBox.shrink();
    }
    if (trimmed.isEmpty && field.blankSpaceOnPrint) {
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('${field.label}:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10.5)),
            for (var i = 0; i < 3; i++)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 10),
                child: pw.Text('_' * 78, style: const pw.TextStyle(fontSize: 10.5)),
              ),
          ],
        ),
      );
    }
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 6),
      child: pw.RichText(
        text: pw.TextSpan(
          children: [
            pw.TextSpan(text: '${field.label}: ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10.5)),
            pw.TextSpan(text: value, style: const pw.TextStyle(fontSize: 10.5)),
          ],
        ),
      ),
    );
  }

  pw.Widget _pdfHeaderCell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9.5)),
      );

  pw.Widget _pdfCell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(
          text,
          style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal),
        ),
      );

  // ---------------------------------------------------------------------
  // DOCX — hand-built minimal OOXML package (no template .docx to fill, and
  // no docx-authoring package dependency). Word/LibreOffice/Google Docs all
  // accept this minimal part set: [Content_Types].xml, _rels/.rels,
  // word/document.xml (+ its rels and docProps for good measure).
  // ---------------------------------------------------------------------

  Future<File> generateDocx(
    LessonPlanTemplate template,
    LessonPlanDraft draft, {
    List<MarkingScheme> relatedMarkingKeys = const [],
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
    addXml('word/document.xml', _buildDocumentXml(template, draft, relatedMarkingKeys));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile('docx', zipped, draft);
  }

  String _buildDocumentXml(LessonPlanTemplate template, LessonPlanDraft draft, List<MarkingScheme> relatedMarkingKeys) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );

    buffer.write(_docxHeading('LESSON PLAN', size: 32, center: true));

    // "evaluation" is rendered after the progression table below — see the
    // matching comment in generatePdf.
    for (final section in template.sections.where((s) => s.id != 'evaluation')) {
      if (section.id != 'header') {
        buffer.write(_docxHeading(section.title, size: 26));
      }
      for (final field in section.fields) {
        buffer.write(_docxField(field, draft.value(field.id)));
      }
    }

    buffer.write(_docxHeading('LESSON PROGRESSION', size: 26));
    buffer.write(_docxProgressionTable(draft));

    for (final section in template.sections.where((s) => s.id == 'evaluation')) {
      buffer.write(_docxHeading(section.title, size: 26));
      for (final field in section.fields) {
        buffer.write(_docxField(field, draft.value(field.id)));
      }
    }

    buffer.write(buildRelatedMarkingKeyDocxSection(relatedMarkingKeys));

    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _docxHeading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="200" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  /// DOCX counterpart to [_pdfField] — same "always print blank ruled lines
  /// for an unfilled handwritten field" behavior.
  String _docxField(LessonPlanFieldDef field, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty && !field.required && !field.blankSpaceOnPrint) return '';
    if (trimmed.isEmpty && field.blankSpaceOnPrint) {
      final buffer = StringBuffer();
      buffer.write(
        '<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>'
        '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(field.label)}:</w:t></w:r></w:p>',
      );
      for (var i = 0; i < 3; i++) {
        buffer.write(
          '<w:p><w:pPr><w:spacing w:before="200"/></w:pPr>'
          '<w:r><w:t xml:space="preserve">${'_' * 78}</w:t></w:r></w:p>',
        );
      }
      return buffer.toString();
    }
    return _docxLabeledParagraph(field.label, value);
  }

  String _docxLabeledParagraph(String label, String value) {
    final buffer = StringBuffer();
    final lines = value.isEmpty ? [''] : value.split('\n');
    buffer.write(
      '<w:p><w:pPr><w:spacing w:after="80"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(label)}: </w:t></w:r>'
      '<w:r><w:t xml:space="preserve">${_xmlEscape(lines.first)}</w:t></w:r></w:p>',
    );
    for (final line in lines.skip(1)) {
      buffer.write(
        '<w:p><w:r><w:t xml:space="preserve">${_xmlEscape(line)}</w:t></w:r></w:p>',
      );
    }
    return buffer.toString();
  }

  String _docxProgressionTable(LessonPlanDraft draft) {
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
    buffer.write(_docxTableRow(['Stage', "Teacher's Role", "Learners' Role", 'Assessment Criteria'], bold: true));
    for (final row in draft.progression) {
      final stageCell = row.durationMinutes.trim().isEmpty ? row.stage : '${row.stage} (${row.durationMinutes})';
      buffer.write(_docxTableRow([stageCell, row.teacherRole, row.learnersRole, row.assessmentCriteria]));
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  String _docxTableRow(List<String> cells, {bool bold = false}) {
    final buffer = StringBuffer('<w:tr>');
    for (final cell in cells) {
      final rPr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
      buffer.write(
        '<w:tc><w:tcPr><w:tcW w:w="2500" w:type="dxa"/></w:tcPr>'
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
      '<dc:title>Lesson Plan</dc:title>'
      '<dc:creator>Zambian Curriculum Companion</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Zambian Curriculum Companion</Application>'
      '</Properties>';
}
