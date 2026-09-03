import 'dart:convert';

import 'package:archive/archive.dart';

import '../models/report_class.dart';
import '../services/report_comment_engine.dart';

/// Everything one learner's report form needs, already resolved — the
/// mail-merge "row" for Report Form Pipeline Stage 10. Built by the caller
/// (see BroadMarkSheetScreen/report-generation flow) from
/// [ReportClassRepository], kept separate from that repository so this
/// document service has no direct database dependency.
class ReportFormMailMergeData {
  final ReportClass reportClass;
  final ReportLearner learner;
  final List<ReportSubject> subjects;

  /// Keyed by subject id — the resolved score (composite-aware) for this
  /// learner, or null if not yet entered.
  final Map<int, double?> scores;

  /// Keyed by subject id — the comment for this learner's subject (auto
  /// or manual, see Stage 11), or null/blank if the subject teacher chose
  /// to leave it for later.
  final Map<int, String?> comments;

  final int? classPosition;
  final int classSize;
  final String attendanceText;

  const ReportFormMailMergeData({
    required this.reportClass,
    required this.learner,
    required this.subjects,
    required this.scores,
    required this.comments,
    this.classPosition,
    required this.classSize,
    this.attendanceText = '',
  });
}

/// Report Form Pipeline, Stage 9 (the template) + Stage 10 (mail-merge
/// generation) + Stage 12 (embedding a Head Teacher signature image) — an
/// **original** report form layout built fresh from standard Zambian
/// secondary-school report form conventions (school name / learner details
/// / one row per subject with score+grade+comment / class position /
/// attendance / signatures), per the brief's own explicit instruction not
/// to copy any specific existing document's design. Hand-rolled minimal
/// OOXML, same no-dependency approach as every other document service in
/// this app (see LessonPlanDocumentService/SchemeOfWorkDocumentService) —
/// the one genuinely new piece here is embedding a real image (the Head
/// Teacher's signature, Stage 12) into that same minimal package, which no
/// earlier service in this app has needed before; see [_buildDocumentXml]
/// and the media/relationship parts added only when a signature is given.
class ReportFormDocumentService {
  /// Generates one learner's report form. [signatureImageBytes]/[signedByName]
  /// are both null for an unsigned (Stage 10) report; both must be given
  /// together for a signed (Stage 12) one — see
  /// GeneratedReportFormRepository.markSigned, the only caller that passes
  /// them.
  List<int> generateForLearner(
    ReportFormMailMergeData data, {
    List<int>? signatureImageBytes,
    String? signedByName,
  }) {
    final archive = Archive();
    void addBytes(String name, List<int> bytes) => archive.addFile(ArchiveFile(name, bytes.length, bytes));
    void addXml(String name, String xml) => addBytes(name, utf8.encode(xml));

    final hasSignature = signatureImageBytes != null && signatureImageBytes.isNotEmpty;

    addXml('[Content_Types].xml', _contentTypesXml(hasSignature));
    addXml('_rels/.rels', _packageRelsXml);
    addXml('word/_rels/document.xml.rels', _documentRelsXml(hasSignature));
    addXml('docProps/core.xml', _corePropsXml);
    addXml('docProps/app.xml', _appPropsXml);
    addXml('word/document.xml', _buildDocumentXml(data, hasSignature: hasSignature, signedByName: signedByName));
    if (hasSignature) addBytes('word/media/signature.png', signatureImageBytes);

    return ZipEncoder().encode(archive);
  }

  /// Stage 14 — "Print" is available at the Broad Mark Sheet stage too,
  /// not just the individual report form stage: a simple table document
  /// (every learner x every subject's resolved score) sharable/printable
  /// the same way as anything else in this app (via the OS share sheet —
  /// see BroadMarkSheetScreen). No signature/mail-merge involved, so this
  /// bypasses [generateForLearner] entirely rather than looping it once
  /// per learner.
  List<int> generateBroadMarkSheetDocx({
    required ReportClass reportClass,
    required List<ReportLearner> learners,
    required List<ReportSubject> subjects,
    required Map<int, Map<int, double?>> scoresByLearnerThenSubject,
  }) {
    final archive = Archive();
    void addXml(String name, String xml) => archive.addFile(ArchiveFile(name, utf8.encode(xml).length, utf8.encode(xml)));

    addXml('[Content_Types].xml', _contentTypesXml(false));
    addXml('_rels/.rels', _packageRelsXml);
    addXml('word/_rels/document.xml.rels', _documentRelsXml(false));
    addXml('docProps/core.xml', _corePropsXml);
    addXml('docProps/app.xml', _appPropsXml);

    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_heading(reportClass.schoolName.toUpperCase()));
    buffer.write(_subheading('BROAD MARK SHEET — ${reportClass.classGrade} — ${reportClass.term}'));
    buffer.write(_spacer());

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
    buffer.write(_tableRow(['Learner', for (final s in subjects) s.name], bold: true));
    for (final learner in learners) {
      buffer.write(_tableRow([
        learner.fullName,
        for (final s in subjects) scoresByLearnerThenSubject[learner.id]?[s.id]?.toStringAsFixed(0) ?? '—',
      ]));
    }
    buffer.write('</w:tbl>');
    buffer.write('<w:sectPr><w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/></w:sectPr></w:body></w:document>');

    addXml('word/document.xml', buffer.toString());
    return ZipEncoder().encode(archive);
  }

  String _buildDocumentXml(ReportFormMailMergeData data, {required bool hasSignature, String? signedByName}) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document '
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<w:body>',
    );

    buffer.write(_heading(data.reportClass.schoolName.toUpperCase()));
    buffer.write(_subheading('SECONDARY SCHOOL REPORT FORM'));
    buffer.write(_spacer());

    buffer.write(_labeledLine('Learner Name', data.learner.fullName));
    buffer.write(_labeledLine('Class', data.reportClass.classGrade));
    buffer.write(_labeledLine('Term', data.reportClass.term));
    buffer.write(_labeledLine(
      'Position in Class',
      data.classPosition == null ? 'Not yet ranked' : '${data.classPosition} out of ${data.classSize}',
    ));
    buffer.write(_labeledLine('Attendance', data.attendanceText.isEmpty ? '—' : data.attendanceText));
    buffer.write(_spacer());

    buffer.write(_subjectsTable(data));
    buffer.write(_spacer());

    buffer.write(_signatureSection(hasSignature: hasSignature, signedByName: signedByName));

    buffer.write('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body></w:document>');
    return buffer.toString();
  }

  String _heading(String text) =>
      '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="60"/></w:pPr>'
      '<w:r><w:rPr><w:b/><w:sz w:val="32"/></w:rPr>'
      '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';

  String _subheading(String text) =>
      '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="200"/></w:pPr>'
      '<w:r><w:rPr><w:sz w:val="24"/></w:rPr>'
      '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';

  String _spacer() => '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>';

  String _labeledLine(String label, String value) =>
      '<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(label)}: </w:t></w:r>'
      '<w:r><w:t xml:space="preserve">${_xmlEscape(value)}</w:t></w:r></w:p>';

  String _subjectsTable(ReportFormMailMergeData data) {
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
    buffer.write(_tableRow(['Subject', 'Score (%)', 'Grade', 'Comment'], bold: true));
    for (final subject in data.subjects) {
      final score = data.scores[subject.id];
      buffer.write(_tableRow([
        subject.name,
        score?.toStringAsFixed(0) ?? '—',
        score == null ? '—' : reportGradeFor(score),
        data.comments[subject.id] ?? '',
      ]));
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  String _tableRow(List<String> cells, {bool bold = false}) {
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

  String _signatureSection({required bool hasSignature, String? signedByName}) {
    final buffer = StringBuffer();
    buffer.write(_labeledLine('Class / Subject Teacher', ''));
    buffer.write(_spacer());
    buffer.write('<w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Head Teacher / Deputy: </w:t></w:r></w:p>');
    if (hasSignature) {
      buffer.write(_signatureImageParagraph());
      buffer.write(_labeledLine('Approved by', signedByName ?? ''));
    } else {
      buffer.write(_spacer());
      buffer.write(_labeledLine('Signature', '________________________'));
    }
    return buffer.toString();
  }

  /// Standard OOXML DrawingML inline-image markup — the one genuinely new
  /// XML shape in this app's hand-rolled document services (every earlier
  /// one is text/table only). Sized ~2in x 0.6in (EMU: 914400 per inch).
  String _signatureImageParagraph() =>
      '<w:p><w:r><w:drawing>'
      '<wp:inline distT="0" distB="0" distL="0" distR="0" '
      'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">'
      '<wp:extent cx="1828800" cy="548640"/>'
      '<wp:docPr id="1" name="Signature"/>'
      '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
      '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:nvPicPr><pic:cNvPr id="1" name="Signature"/><pic:cNvPicPr/></pic:nvPicPr>'
      '<pic:blipFill><a:blip r:embed="rIdSignature"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
      '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1828800" cy="548640"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
      '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';

  String _xmlEscape(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  String _contentTypesXml(bool hasSignature) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '${hasSignature ? '<Default Extension="png" ContentType="image/png"/>' : ''}'
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

  String _documentRelsXml(bool hasSignature) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${hasSignature ? '<Relationship Id="rIdSignature" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
          'Target="media/signature.png"/>' : ''}'
      '</Relationships>';

  static const _corePropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties '
      'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>Report Form</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';
}
