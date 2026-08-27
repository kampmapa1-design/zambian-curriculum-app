import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/syllabus_models.dart';

/// Renders a whole [SyllabusTemplate] — every term, topic, sub-topic,
/// objective and competency — as a PDF or Word (.docx) file, entirely
/// on-device, for a teacher to print or share the full syllabus on demand.
/// Mirrors [LessonPlanDocumentService]'s hand-built-OOXML approach for
/// consistency and to avoid a second docx-authoring dependency.
class SyllabusDocumentService {
  String _fileBaseName(SyllabusTemplate template) {
    final raw = '${template.subject.name}_${template.grade.name}';
    final safe = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'syllabus' : safe;
  }

  Future<File> _writeToTempFile(String extension, List<int> bytes, SyllabusTemplate template) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_fileBaseName(template)}.$extension');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  // ---------------------------------------------------------------------
  // PDF
  // ---------------------------------------------------------------------

  Future<File> generatePdf(SyllabusTemplate template) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) => [
          pw.Center(
            child: pw.Text(
              '${template.subject.name} — ${template.grade.name}',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Center(
            child: pw.Text(template.curriculum.name, style: const pw.TextStyle(fontSize: 10.5)),
          ),
          pw.SizedBox(height: 16),
          for (final term in template.terms) ...[
            pw.Text(term.name, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.Divider(thickness: 0.5),
            for (final topic in term.topics) ..._pdfTopic(topic),
            pw.SizedBox(height: 10),
          ],
        ],
      ),
    );
    final bytes = await doc.save();
    return _writeToTempFile('pdf', bytes, template);
  }

  List<pw.Widget> _pdfTopic(Topic topic) => [
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 8, bottom: 2),
          child: pw.Text(topic.name, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        ),
        if (topic.description != null)
          pw.Text(topic.description!, style: pw.TextStyle(fontSize: 10, fontStyle: pw.FontStyle.italic)),
        if (topic.objectives.isNotEmpty) _pdfBullets('Learning objectives', topic.objectives.map((o) => o.description)),
        if (topic.competencies.isNotEmpty) _pdfBullets('Competencies', topic.competencies.map((c) => c.description)),
        for (final sub in topic.subTopics) ..._pdfSubTopic(sub),
      ];

  List<pw.Widget> _pdfSubTopic(SubTopic sub) => [
        pw.Padding(
          padding: const pw.EdgeInsets.only(left: 12, top: 4),
          child: pw.Text(sub.name, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ),
        if (sub.description != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 12),
            child: pw.Text(sub.description!, style: pw.TextStyle(fontSize: 10, fontStyle: pw.FontStyle.italic)),
          ),
        if (sub.objectives.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 12),
            child: _pdfBullets('Learning objectives', sub.objectives.map((o) => o.description)),
          ),
        if (sub.competencies.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 12),
            child: _pdfBullets('Competencies', sub.competencies.map((c) => c.description)),
          ),
      ];

  pw.Widget _pdfBullets(String title, Iterable<String> items) => pw.Padding(
        padding: const pw.EdgeInsets.only(left: 12, top: 2, bottom: 4),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(title, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
            for (final item in items)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 2),
                child: pw.Text('•  $item', style: const pw.TextStyle(fontSize: 9.5)),
              ),
          ],
        ),
      );

  // ---------------------------------------------------------------------
  // DOCX — same hand-built minimal OOXML package as LessonPlanDocumentService.
  // ---------------------------------------------------------------------

  Future<File> generateDocx(SyllabusTemplate template) async {
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
    addXml('word/document.xml', _buildDocumentXml(template));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile('docx', zipped, template);
  }

  String _buildDocumentXml(SyllabusTemplate template) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_heading('${template.subject.name} — ${template.grade.name}', size: 32, center: true));
    buffer.write(_paragraph(template.curriculum.name, italic: true, center: true));
    for (final term in template.terms) {
      buffer.write(_heading(term.name, size: 26));
      for (final topic in term.topics) {
        buffer.write(_docxTopic(topic));
      }
    }
    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _docxTopic(Topic topic) {
    final buffer = StringBuffer();
    buffer.write(_heading(topic.name, size: 22));
    if (topic.description != null) buffer.write(_paragraph(topic.description!, italic: true));
    if (topic.objectives.isNotEmpty) {
      buffer.write(_docxBullets('Learning objectives', topic.objectives.map((o) => o.description)));
    }
    if (topic.competencies.isNotEmpty) {
      buffer.write(_docxBullets('Competencies', topic.competencies.map((c) => c.description)));
    }
    for (final sub in topic.subTopics) {
      buffer.write(_heading(sub.name, size: 20));
      if (sub.description != null) buffer.write(_paragraph(sub.description!, italic: true));
      if (sub.objectives.isNotEmpty) {
        buffer.write(_docxBullets('Learning objectives', sub.objectives.map((o) => o.description)));
      }
      if (sub.competencies.isNotEmpty) {
        buffer.write(_docxBullets('Competencies', sub.competencies.map((c) => c.description)));
      }
    }
    return buffer.toString();
  }

  String _docxBullets(String title, Iterable<String> items) {
    final buffer = StringBuffer();
    buffer.write(_paragraph(title, bold: true));
    for (final item in items) {
      buffer.write(_paragraph('•  $item'));
    }
    return buffer.toString();
  }

  String _heading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="200" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _paragraph(String text, {bool bold = false, bool italic = false, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    final rPr = (bold || italic) ? '<w:rPr>${bold ? '<w:b/>' : ''}${italic ? '<w:i/>' : ''}</w:rPr>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:after="60"/></w:pPr>'
        '<w:r>$rPr<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
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
      '<dc:title>Syllabus</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';
}
