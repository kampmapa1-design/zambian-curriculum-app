import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'marking_gap_report_service.dart';

/// "Report on [Name]" — turns a [MarkingGapReport] into an actual
/// shareable .docx: which of the marking key's ideal answers were found
/// in the script, and which were missing. Same hand-rolled OOXML pattern
/// as every other document service in this app.
class MarkingGapReportDocumentService {
  Future<File> generateDocx(MarkingGapReport report) async {
    final archive = Archive();
    void addXml(String name, String xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    final title = 'Report on ${report.studentName}';
    addXml('[Content_Types].xml', _contentTypesXml);
    addXml('_rels/.rels', _packageRelsXml);
    addXml('word/_rels/document.xml.rels', _documentRelsXml);
    addXml('docProps/core.xml', _corePropsXml(title));
    addXml('docProps/app.xml', _appPropsXml);
    addXml('word/document.xml', _buildDocumentXml(report, title));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile(zipped, title);
  }

  Future<File> _writeToTempFile(List<int> bytes, String title) async {
    final dir = await getTemporaryDirectory();
    final safe = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final path = p.join(dir.path, '${safe.isEmpty ? 'marking_gap_report' : safe}.docx');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _buildDocumentXml(MarkingGapReport report, String title) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_docxHeading(title, size: 32, center: true));
    buffer.write(_docxParagraph('${report.subjectName} — ${report.gradeName}', italic: true));
    buffer.write(_docxParagraph(
      'A simple comparison against the marking key\'s ideal answers, derived from this script\'s AI grading. '
      'Review alongside the full marked script before drawing conclusions.',
      italic: true,
    ));

    buffer.write(_docxHeading('Ideal answers found in this script (${report.present.length})', size: 26));
    if (report.present.isEmpty) {
      buffer.write(_docxParagraph('None.'));
    } else {
      for (final o in report.present) {
        buffer.write(_docxParagraph('${o.questionLabel} (${_fmt(o.marksAwarded)}/${_fmt(o.maxMarks)}): ${o.expectedAnswer}'));
      }
    }

    buffer.write(_docxHeading('Ideal answers missing from this script (${report.missing.length})', size: 26));
    if (report.missing.isEmpty) {
      buffer.write(_docxParagraph('None — every expected answer was found.'));
    } else {
      for (final o in report.missing) {
        buffer.write(_docxParagraph('${o.questionLabel}: ${o.expectedAnswer}'));
      }
    }

    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _fmt(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);

  String _docxHeading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="240" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _docxParagraph(String text, {bool italic = false}) {
    final rPr = italic ? '<w:rPr><w:i/></w:rPr>' : '';
    return '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr>'
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
