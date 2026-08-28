import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'handwritten_list_transcription_service.dart';

/// "Capture Manual Scores" — turns a [TranscribedTable] into an actual
/// editable .docx reproducing whatever pattern/table was on the
/// photographed handwritten list, styled as a real Word table (not a
/// plain-text dump) so it opens ready to review and correct directly in
/// Word, Google Docs, or any compatible app. Hand-built minimal OOXML
/// package — same approach as MarksheetDocumentService/
/// AnalysisDocumentService, no docx-authoring package dependency.
class HandwrittenListDocumentService {
  Future<File> generateDocx(TranscribedTable table, {String title = 'Captured List'}) async {
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
    addXml('word/document.xml', _buildDocumentXml(table, title));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile(zipped, title);
  }

  Future<File> _writeToTempFile(List<int> bytes, String title) async {
    final dir = await getTemporaryDirectory();
    final safe = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final path = p.join(dir.path, '${safe.isEmpty ? 'captured_list' : safe}.docx');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _buildDocumentXml(TranscribedTable table, String title) {
    // Column count follows the widest row (or the header row, if it has
    // more columns than any row) — never assumed as a fixed shape, since
    // the whole point of this feature is reproducing whatever pattern
    // was genuinely on the page.
    var columnCount = table.headers.length;
    for (final row in table.rows) {
      if (row.length > columnCount) columnCount = row.length;
    }
    if (columnCount == 0) columnCount = 1;

    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_docxHeading(title, size: 32, center: true));
    buffer.write(_docxParagraph(
      'Transcribed from a photographed handwritten list — review every cell against the original before relying on it.',
    ));
    if (table.notes.trim().isNotEmpty) {
      buffer.write(_docxParagraph('AI notes: ${table.notes}', italic: true));
    }
    buffer.write(_docxTable(table, columnCount));
    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _docxTable(TranscribedTable table, int columnCount) {
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

    if (table.headers.isNotEmpty) {
      buffer.write(_docxRow(_padded(table.headers, columnCount), bold: true, shaded: true));
    }
    for (final row in table.rows) {
      buffer.write(_docxRow(_padded(row, columnCount), bold: false, shaded: false));
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  List<String> _padded(List<String> cells, int columnCount) =>
      List.generate(columnCount, (i) => i < cells.length ? cells[i] : '');

  String _docxRow(List<String> cells, {required bool bold, required bool shaded}) {
    final buffer = StringBuffer('<w:tr>');
    final shading = shaded ? '<w:shd w:val="clear" w:color="auto" w:fill="D9D9D9"/>' : '';
    for (final cell in cells) {
      final rPr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
      buffer.write(
        '<w:tc><w:tcPr><w:tcW w:w="1600" w:type="dxa"/>$shading</w:tcPr>'
        '<w:p><w:r>$rPr<w:t xml:space="preserve">${_xmlEscape(cell)}</w:t></w:r></w:p></w:tc>',
      );
    }
    buffer.write('</w:tr>');
    return buffer.toString();
  }

  String _docxHeading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="200" w:after="120"/></w:pPr>'
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

  static const _corePropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties '
      'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>Captured List</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';
}
