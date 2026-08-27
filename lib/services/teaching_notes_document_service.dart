import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Renders already-composed teaching notes (offline or AI-generated, bullet
/// or paragraph) as a shareable PDF or Word (.docx) file, entirely
/// on-device. The notes are already plain text by the time they reach here
/// — this just lays that text out as a document, following the same
/// hand-rolled-OOXML pattern as [LessonPlanDocumentService] and
/// [SchemeOfWorkDocumentService] (no docx-authoring dependency needed).
class TeachingNotesDocumentService {
  String _fileBaseName(String title) {
    final safe = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'teaching_notes' : '${safe}_notes';
  }

  Future<File> _writeToTempFile(String extension, List<int> bytes, String title) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_fileBaseName(title)}.$extension');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// A line starting with a bullet marker (as produced by
  /// [OfflineTeachingNotesService]/the AI prompt's bullet format) renders
  /// as an indented bullet; a bare heading-like line (ends with ':' or is
  /// the very first line) renders bold; everything else is a plain
  /// paragraph.
  bool _isBullet(String line) => RegExp(r'^[•\-\*]\s+').hasMatch(line);

  String _stripBulletMarker(String line) => line.replaceFirst(RegExp(r'^[•\-\*]\s+'), '');

  // ---------------------------------------------------------------------
  // PDF
  // ---------------------------------------------------------------------

  Future<File> generatePdf({required String title, required String notes}) async {
    final doc = pw.Document();
    final lines = notes.split('\n');

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) => [
          pw.Text('TEACHING NOTES', style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700)),
          pw.SizedBox(height: 4),
          pw.Text(title, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 12),
          for (final line in lines) _pdfLine(line),
        ],
      ),
    );

    final bytes = await doc.save();
    return _writeToTempFile('pdf', bytes, title);
  }

  pw.Widget _pdfLine(String line) {
    if (line.trim().isEmpty) return pw.SizedBox(height: 8);
    if (_isBullet(line)) {
      return pw.Padding(
        padding: const pw.EdgeInsets.only(left: 12, bottom: 4),
        child: pw.Bullet(text: _stripBulletMarker(line), style: const pw.TextStyle(fontSize: 11)),
      );
    }
    final isHeading = line.trim().endsWith(':') && line.trim().length < 60;
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 6),
      child: pw.Text(
        line,
        style: pw.TextStyle(fontSize: isHeading ? 12 : 11, fontWeight: isHeading ? pw.FontWeight.bold : null),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // DOCX
  // ---------------------------------------------------------------------

  Future<File> generateDocx({required String title, required String notes}) async {
    final archive = Archive();
    void addXml(String name, String xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    addXml('[Content_Types].xml', _contentTypesXml);
    addXml('_rels/.rels', _packageRelsXml);
    addXml('word/_rels/document.xml.rels', _documentRelsXml);
    addXml('docProps/core.xml', _corePropsXml(title));
    addXml('docProps/app.xml', _appPropsXml);
    addXml('word/document.xml', _buildDocumentXml(title, notes));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile('docx', zipped, title);
  }

  String _buildDocumentXml(String title, String notes) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_docxHeading('TEACHING NOTES', size: 20));
    buffer.write(_docxHeading(title, size: 32));
    for (final line in notes.split('\n')) {
      buffer.write(_docxLine(line));
    }
    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _docxHeading(String text, {int size = 24}) {
    return '<w:p><w:pPr><w:spacing w:before="100" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _docxLine(String line) {
    if (line.trim().isEmpty) {
      return '<w:p/>';
    }
    if (_isBullet(line)) {
      return '<w:p><w:pPr><w:ind w:left="360"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="0"/></w:numPr></w:pPr>'
          '<w:r><w:t xml:space="preserve">•  ${_xmlEscape(_stripBulletMarker(line))}</w:t></w:r></w:p>';
    }
    final isHeading = line.trim().endsWith(':') && line.trim().length < 60;
    final rPr = isHeading ? '<w:rPr><w:b/></w:rPr>' : '';
    return '<w:p><w:pPr><w:spacing w:after="80"/></w:pPr>'
        '<w:r>$rPr<w:t xml:space="preserve">${_xmlEscape(line)}</w:t></w:r></w:p>';
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

  String _corePropsXml(String title) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties '
      'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>${_xmlEscape(title)}</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';
}
