import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart' as xml;

/// Extracts candidate section headings from a .docx file's bytes, in
/// document order — the first step of Stage 3's "Upload My Own Template"
/// flow, entirely on-device (unzips the .docx as a plain OOXML package and
/// reads its `word/document.xml`, the same format
/// `LessonPlanDocumentService`/`SchemeOfWorkDocumentService` already write).
///
/// PDF templates aren't supported yet — reliable text extraction from PDF
/// needs a heavier dependency than this app currently takes on; DOCX only
/// for now.
class DocxHeadingExtractor {
  List<String> extractHeadings(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? documentFile;
    for (final f in archive.files) {
      if (f.name == 'word/document.xml') {
        documentFile = f;
        break;
      }
    }
    if (documentFile == null) {
      throw const FormatException('Not a valid .docx file (missing word/document.xml).');
    }

    final xmlString = String.fromCharCodes(documentFile.content as List<int>);
    final document = xml.XmlDocument.parse(xmlString);

    final headings = <String>[];
    for (final p in document.findAllElements('w:p')) {
      final text = _paragraphText(p).trim();
      if (text.isEmpty) continue;
      if (_looksLikeHeading(p, text)) headings.add(text);
    }
    return headings;
  }

  String _paragraphText(xml.XmlElement p) {
    final buffer = StringBuffer();
    for (final t in p.findAllElements('w:t')) {
      for (final child in t.children) {
        if (child is xml.XmlText) buffer.write(child.value);
      }
    }
    return buffer.toString();
  }

  /// A paragraph counts as a heading if Word tagged it with a "Heading" or
  /// "Title" paragraph style. Falls back to "short and entirely bold, not a
  /// full sentence" for documents that were formatted by hand without using
  /// styles — common in templates typed up locally rather than from a
  /// Word template gallery.
  bool _looksLikeHeading(xml.XmlElement p, String text) {
    final styleEls = p.findAllElements('w:pStyle').toList();
    final styleVal = styleEls.isEmpty ? '' : (styleEls.first.getAttribute('w:val') ?? '');
    if (styleVal.toLowerCase().contains('heading') || styleVal.toLowerCase().contains('title')) {
      return true;
    }
    final isBold = p.findAllElements('w:b').isNotEmpty;
    final isShort = text.length <= 80;
    final looksLikeLabel = !text.endsWith('.');
    return isBold && isShort && looksLikeLabel;
  }
}
