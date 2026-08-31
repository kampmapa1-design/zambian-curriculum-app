import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'minutes_reconstruction_service.dart';

/// Minutes Maker, Stage 8 — renders a [ReconstructedMinutes] as a PDF or
/// Word (.docx) file, entirely on-device, matching the app's existing
/// export style: the `pdf` package for PDF (same pattern as
/// RecordOfWorkDocumentService), a hand-rolled OOXML writer for DOCX (same
/// pattern as MarkingGapReportDocumentService).
class MinutesDocumentService {
  String _fileBaseName(String meetingTitle, DateTime meetingDate) {
    final dateStr = '${meetingDate.year}-${meetingDate.month.toString().padLeft(2, '0')}-'
        '${meetingDate.day.toString().padLeft(2, '0')}';
    final raw = '${meetingTitle}_$dateStr';
    final safe = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'meeting_minutes' : safe;
  }

  Future<File> generatePdf(ReconstructedMinutes minutes, DateTime meetingDate) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) => [
          pw.Center(
            child: pw.Text(
              minutes.meetingTitle,
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
              textAlign: pw.TextAlign.center,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              '${meetingDate.year}-${meetingDate.month.toString().padLeft(2, '0')}-'
              '${meetingDate.day.toString().padLeft(2, '0')}',
              style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
            ),
          ),
          pw.SizedBox(height: 20),
          for (final section in minutes.sections) ...[
            pw.Text(section.heading, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            // pw.Bullet (2026-08-31), not a literal '•' character in
            // pw.Text — the Unicode bullet glyph isn't reliably present in
            // the plain Helvetica this document uses, and rendered as a
            // visible "missing glyph" box on real devices (a real,
            // confirmed report, not a hypothetical). pw.Bullet draws its
            // marker as an actual small circle shape, not a font glyph, so
            // it can't ever tofu regardless of what font is in play.
            for (final line in section.lines)
              pw.Bullet(text: line, style: const pw.TextStyle(fontSize: 11)),
            pw.SizedBox(height: 14),
          ],
        ],
      ),
    );

    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, '${_fileBaseName(minutes.meetingTitle, meetingDate)}.pdf'));
    await file.writeAsBytes(await doc.save(), flush: true);
    return file;
  }

  Future<File> generateDocx(ReconstructedMinutes minutes, DateTime meetingDate) async {
    final archive = Archive();
    void addXml(String name, String xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    addXml('[Content_Types].xml', _contentTypesXml);
    addXml('_rels/.rels', _packageRelsXml);
    addXml('word/_rels/document.xml.rels', _documentRelsXml);
    addXml('docProps/core.xml', _corePropsXml(minutes.meetingTitle));
    addXml('docProps/app.xml', _appPropsXml);
    addXml('word/document.xml', _buildDocumentXml(minutes, meetingDate));

    final zipped = ZipEncoder().encode(archive);
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, '${_fileBaseName(minutes.meetingTitle, meetingDate)}.docx'));
    await file.writeAsBytes(zipped, flush: true);
    return file;
  }

  String _buildDocumentXml(ReconstructedMinutes minutes, DateTime meetingDate) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_docxHeading(minutes.meetingTitle, size: 32, center: true));
    final dateStr = '${meetingDate.year}-${meetingDate.month.toString().padLeft(2, '0')}-'
        '${meetingDate.day.toString().padLeft(2, '0')}';
    buffer.write(_docxParagraph(dateStr, italic: true, center: true));

    for (final section in minutes.sections) {
      buffer.write(_docxHeading(section.heading, size: 26));
      for (final line in section.lines) {
        buffer.write(_docxBullet(line));
      }
    }

    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _docxHeading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="240" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _docxParagraph(String text, {bool italic = false, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    final rPr = italic ? '<w:rPr><w:i/></w:rPr>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:after="120"/></w:pPr>'
        '<w:r>$rPr<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _docxBullet(String text) =>
      '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>'
      '<w:spacing w:after="80"/></w:pPr>'
      '<w:r><w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';

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
