import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'handwriting_document_transcription_service.dart';

/// "Handwriting to Word Document Conversion" — turns a [TranscribedDocument]
/// into an actual editable .docx with real headings/paragraphs/lists,
/// reproducing the structure of whatever was photographed/uploaded. Hand-
/// built minimal OOXML package — same approach as
/// HandwrittenListDocumentService/MarksheetDocumentService, no
/// docx-authoring package dependency.
class HandwritingDocumentService {
  Future<File> generateDocx(TranscribedDocument document) async {
    final archive = Archive();
    void addXml(String name, String xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    addXml('[Content_Types].xml', _contentTypesXml);
    addXml('_rels/.rels', _packageRelsXml);
    addXml('word/_rels/document.xml.rels', _documentRelsXml);
    addXml('docProps/core.xml', _corePropsXml(document.title));
    addXml('docProps/app.xml', _appPropsXml);
    addXml('word/document.xml', _buildDocumentXml(document));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile(zipped, document.title);
  }

  Future<File> _writeToTempFile(List<int> bytes, String title) async {
    final dir = await getTemporaryDirectory();
    final safe = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final path = p.join(dir.path, '${safe.isEmpty ? 'converted_document' : safe}.docx');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _buildDocumentXml(TranscribedDocument document) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_docxHeading(document.title, size: 32, center: true));
    buffer.write(_docxParagraph(
      'Converted from a photographed/uploaded handwritten document — review against the original before relying on it.',
      italic: true,
    ));
    if (document.notes.trim().isNotEmpty) {
      buffer.write(_docxParagraph('AI notes: ${document.notes}', italic: true));
    }

    var numberedCount = 0;
    for (final block in document.blocks) {
      if (block.type != DocumentBlockType.numbered) numberedCount = 0;
      switch (block.type) {
        case DocumentBlockType.heading:
          buffer.write(_docxHeading(block.text, size: 28));
          break;
        case DocumentBlockType.subheading:
          buffer.write(_docxHeading(block.text, size: 24));
          break;
        case DocumentBlockType.paragraph:
          buffer.write(_docxParagraph(block.text));
          break;
        case DocumentBlockType.bullet:
          buffer.write(_docxParagraph('•   ${block.text}', indent: true));
          break;
        case DocumentBlockType.numbered:
          numberedCount++;
          buffer.write(_docxParagraph('$numberedCount.   ${block.text}', indent: true));
          break;
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

  String _docxParagraph(String text, {bool italic = false, bool indent = false}) {
    final rPr = italic ? '<w:rPr><w:i/></w:rPr>' : '';
    final ind = indent ? '<w:ind w:left="360"/>' : '';
    return '<w:p><w:pPr>$ind<w:spacing w:after="120"/></w:pPr>'
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
