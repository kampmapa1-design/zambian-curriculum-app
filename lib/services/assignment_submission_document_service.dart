import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/assignment_submission.dart';

/// Assignment Submission, Stages 5-7 (redesigned 2026-09-02 per explicit
/// request): the "processed and sent work" is now a real, editable Word
/// document — not a PDF — hand-built minimal OOXML, same approach as
/// `HandwritingDocumentService`/`HandwrittenListDocumentService` elsewhere
/// in this app, no docx-authoring package dependency. The originally
/// captured pages (cover + body + references) are bundled as a single
/// *viewable* PDF (one photo per page) rather than a .zip archive — a zip
/// needs an extraction step a phone may not have handy; every phone can
/// already open a PDF. Both together are this submission's two-file
/// "authoritative backup, readable and viewable, accompanied by the Word
/// document" — see AssignmentSubmissionScreen._send() for how they're
/// attached. SHA-256 + submission timestamp (Stage 6) are computed over
/// the Word doc now, since that's the actual sent/processed artifact.
class AssignmentSubmissionDocumentService {
  Future<File> _writeToSubmissionDir(Directory dir, String fileName, List<int> bytes) async {
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  // -------------------------------------------------------------------
  // Word document (.docx) — the processed, sent work.
  // -------------------------------------------------------------------

  /// Stage 6's timestamp requirement is embedded in the docx's own core
  /// properties (`dc:description`) — decided here, before this document's
  /// bytes are ever hashed, so there's no circularity with
  /// [computeSha256]. The hash itself is never embedded inside the
  /// document it describes (that would require hashing the document,
  /// then re-hashing after embedding the hash, which never actually
  /// terminates) — it's recorded on the submission record and shown to
  /// the student on the Stage 9 confirmation screen instead.
  Future<File> generateConsolidatedDocx({
    required AssignmentSubmission submission,
    required Directory submissionDir,
    required DateTime submittedAt,
  }) async {
    final title = submission.assignmentTitle.isEmpty ? 'Assignment Submission' : submission.assignmentTitle;
    final archive = Archive();
    void addXml(String name, String xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    addXml('[Content_Types].xml', _contentTypesXml);
    addXml('_rels/.rels', _packageRelsXml);
    addXml('word/_rels/document.xml.rels', _documentRelsXml);
    addXml('docProps/core.xml', _corePropsXml(title, submittedAt));
    addXml('docProps/app.xml', _appPropsXml);
    addXml('word/document.xml', _buildDocumentXml(submission));

    final bytes = ZipEncoder().encode(archive);
    return _writeToSubmissionDir(submissionDir, 'submission.docx', bytes);
  }

  String _buildDocumentXml(AssignmentSubmission submission) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_docxHeading('COVER PAGE', size: 32, center: true));
    buffer.write(_coverField('Student Name', submission.studentName));
    buffer.write(_coverField('ID / Registration Number', submission.idNumber));
    buffer.write(_coverField('Course', submission.course));
    buffer.write(_coverField('Subject', submission.subject));
    buffer.write(_coverField('Assignment Title', submission.assignmentTitle));
    buffer.write(_coverField('Lecturer / Teacher Name', submission.teacherName));
    buffer.write(_coverField('Date', submission.date));
    buffer.write(_coverField('Institution', submission.institution));

    buffer.write(_docxHeading('INTRODUCTION / MAIN BODY / CONCLUSION', size: 28));
    for (final block in submission.transcribedBody) {
      buffer.write(_bodyBlock(block));
    }

    if (submission.referenceSystem != ReferenceSystem.none && submission.transcribedReferences.isNotEmpty) {
      buffer.write(_docxHeading('REFERENCES (${submission.referenceSystem.label})', size: 28));
      for (final entry in submission.transcribedReferences) {
        buffer.write(_referenceParagraph(entry));
      }
    }

    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _coverField(String label, String value) =>
      '<w:p><w:pPr><w:spacing w:after="80"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(label)}: </w:t></w:r>'
      '<w:r><w:t xml:space="preserve">${_xmlEscape(value.isEmpty ? '(not provided)' : value)}</w:t></w:r></w:p>';

  String _bodyBlock(AssignmentBodyBlock block) {
    switch (block.type) {
      case AssignmentBodyBlockType.heading:
        return _docxHeading(block.text, size: 26);
      case AssignmentBodyBlockType.subheading:
        return _docxHeading(block.text, size: 23);
      case AssignmentBodyBlockType.bullet:
        return _docxParagraph('•   ${block.text}', indent: true);
      case AssignmentBodyBlockType.numbered:
        return _docxParagraph('•   ${block.text}', indent: true);
      case AssignmentBodyBlockType.paragraph:
        return _docxParagraph(block.text);
    }
  }

  /// Reproduces the `*asterisks*` italics marker the transcription prompt
  /// asks for as alternating normal/italic runs within one paragraph.
  String _referenceParagraph(String entry) {
    final parts = entry.split('*');
    final runs = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      final rPr = i.isOdd ? '<w:rPr><w:i/></w:rPr>' : '';
      runs.write('<w:r>$rPr<w:t xml:space="preserve">${_xmlEscape(parts[i])}</w:t></w:r>');
    }
    return '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr>$runs</w:p>';
  }

  String _docxHeading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="240" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _docxParagraph(String text, {bool indent = false}) {
    final ind = indent ? '<w:ind w:left="360"/>' : '';
    return '<w:p><w:pPr>$ind<w:spacing w:after="120"/></w:pPr>'
        '<w:r><w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
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

  String _corePropsXml(String title, DateTime submittedAt) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties '
      'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>${_xmlEscape(title)}</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '<dc:description>submittedAt:${submittedAt.toIso8601String()}</dc:description>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';

  // -------------------------------------------------------------------
  // Viewable image PDF — the authoritative, compressed backup of every
  // originally captured page (cover + body + references), one photo per
  // page. Replaces the earlier .zip bundle (2026-09-02): every phone can
  // already open a PDF; not every phone has a zip extractor handy.
  // -------------------------------------------------------------------

  Future<File> generateImageBundle({
    required AssignmentSubmission submission,
    required Directory submissionDir,
  }) async {
    final fileNames = [
      if (submission.coverPhotoFileName != null) submission.coverPhotoFileName!,
      ...submission.bodyPageFileNames,
      ...submission.referencePageFileNames,
    ];

    final doc = pw.Document();
    for (final name in fileNames) {
      final file = File(p.join(submissionDir.path, name));
      if (!await file.exists()) continue;
      final image = pw.MemoryImage(await file.readAsBytes());
      doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, build: (context) => pw.Center(child: pw.Image(image))));
    }

    final bytes = await doc.save();
    return _writeToSubmissionDir(submissionDir, 'original_pages.pdf', bytes);
  }

  /// SHA-256 of the given file's actual bytes on disk — called with the
  /// Word doc, the actual "processed and sent" artifact (2026-09-02).
  Future<String> computeSha256(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// Stage 7 — both files already live permanently in [submissionDir]
  /// (part of [AssignmentSubmissionRepository]'s own on-device storage,
  /// never cleared by a successful or failed send).
  Directory permanentCopyLocation(Directory submissionDir) => submissionDir;
}
