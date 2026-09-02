import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/test_submission.dart';

/// Test Submission, Stages 4-6 (redesigned 2026-09-02 per explicit
/// request, mirrors AssignmentSubmissionDocumentService exactly): the
/// "processed and sent work" is a real, editable Word document — hand-
/// built minimal OOXML, same approach used throughout this app, no
/// docx-authoring package dependency. Segments are rendered in
/// transcription order (page order), each tagged with its detected
/// question number, never regrouped — preserving both page order and
/// question-number structure at once, exactly as specified. The
/// originally captured pages are bundled as a single *viewable* PDF (one
/// photo per page), not a .zip — every phone can already open a PDF.
class TestSubmissionDocumentService {
  Future<File> _writeToSubmissionDir(Directory dir, String fileName, List<int> bytes) async {
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  // -------------------------------------------------------------------
  // Word document (.docx) — the processed, sent work.
  // -------------------------------------------------------------------

  /// Stage 6's timestamp is embedded in the docx's own core properties
  /// (`dc:description`), decided before this document's bytes are ever
  /// hashed — same non-circular approach as
  /// AssignmentSubmissionDocumentService (see its doc comment).
  Future<File> generateConsolidatedDocx({
    required TestSubmission submission,
    required Directory submissionDir,
    required DateTime submittedAt,
  }) async {
    final title = submission.subjectName.isEmpty ? 'Test Submission' : '${submission.subjectName} Test Submission';
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
    addXml('word/document.xml', _buildDocumentXml(submission, submittedAt));

    final bytes = ZipEncoder().encode(archive);
    return _writeToSubmissionDir(submissionDir, 'submission.docx', bytes);
  }

  String _buildDocumentXml(TestSubmission submission, DateTime submittedAt) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_docxHeading('TEST SUBMISSION', size: 32, center: true));
    buffer.write(_coverField('Student Name', submission.studentName));
    buffer.write(_coverField('Subject', submission.subjectName));
    buffer.write(_coverField('Grade', submission.gradeName));
    buffer.write(_coverField('School / Institution', submission.institution));
    buffer.write(_coverField('Submitted', submittedAt.toLocal().toString()));

    buffer.write(_docxHeading('ANSWERS', size: 28));
    for (final segment in submission.segments) {
      buffer.write(_segment(segment));
    }

    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _coverField(String label, String value) =>
      '<w:p><w:pPr><w:spacing w:after="80"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(label)}: </w:t></w:r>'
      '<w:r><w:t xml:space="preserve">${_xmlEscape(value.isEmpty ? '(not provided)' : value)}</w:t></w:r></w:p>';

  String _segment(TestAnswerSegment segment) =>
      '<w:p><w:pPr><w:spacing w:before="160" w:after="40"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(segment.questionNumber)}</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr>'
      '<w:r><w:t xml:space="preserve">${_xmlEscape(segment.text)}</w:t></w:r></w:p>';

  String _docxHeading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="240" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
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
  // originally captured page, one photo per page. Replaces the earlier
  // .zip bundle (2026-09-02) — every phone can already open a PDF.
  // -------------------------------------------------------------------

  Future<File> generateImageBundle({
    required TestSubmission submission,
    required Directory submissionDir,
  }) async {
    final doc = pw.Document();
    for (final name in submission.pageFileNames) {
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

  /// Stage 5 — both files already live permanently in [submissionDir]
  /// (part of [TestSubmissionRepository]'s own on-device storage, never
  /// cleared by a successful or failed send).
  Directory permanentCopyLocation(Directory submissionDir) => submissionDir;
}
