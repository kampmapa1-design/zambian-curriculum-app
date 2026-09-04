import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/report_class.dart';

/// A short, one-page "your child is registered" confirmation slip — the
/// real attachment behind Class Roster's guardian notification (2026-09-04,
/// per explicit request: "the app should be able to send all three types
/// of messages"). Built fresh at this early stage of the Report Form
/// Pipeline specifically because no report form exists yet to attach —
/// Email and WhatsApp both need a real file to be a genuine send rather
/// than text alone (see ReportFormListScreen's own fix for exactly this),
/// so this gives them one. Deliberately minimal: nothing here claims a
/// score, grade, or result — only what's actually true this early
/// (learner is on the class roster).
class RosterConfirmationDocumentService {
  Future<File> generate({required ReportClass reportClass, required ReportLearner learner}) async {
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
    addXml('word/document.xml', _buildDocumentXml(reportClass, learner));

    final zipped = ZipEncoder().encode(archive);
    final dir = await getTemporaryDirectory();
    final safeName = learner.fullName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final file = File(p.join(dir.path, 'registration_confirmation_$safeName.docx'));
    await file.writeAsBytes(zipped, flush: true);
    return file;
  }

  String _buildDocumentXml(ReportClass reportClass, ReportLearner learner) {
    final now = DateTime.now();
    final dateStr = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_heading(reportClass.schoolName.toUpperCase()));
    buffer.write(_subheading('CLASS REGISTRATION CONFIRMATION'));
    buffer.write(_spacer());
    buffer.write(_line('Learner', learner.fullName));
    buffer.write(_line('Class', reportClass.classGrade));
    buffer.write(_line('Term', reportClass.term));
    buffer.write(_line('Date', dateStr));
    buffer.write(_spacer());
    buffer.write(_paragraph(
      '${learner.fullName} is registered on the class roster for ${reportClass.classGrade}, '
      '${reportClass.term}. This is a registration confirmation only — no scores or results are '
      'included. Report forms will be sent separately once ready.',
    ));
    buffer.write('<w:sectPr/></w:body></w:document>');
    return buffer.toString();
  }

  String _heading(String text) =>
      '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="60"/></w:pPr>'
      '<w:r><w:rPr><w:b/><w:sz w:val="30"/></w:rPr>'
      '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';

  String _subheading(String text) =>
      '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="180"/></w:pPr>'
      '<w:r><w:rPr><w:sz w:val="22"/></w:rPr>'
      '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';

  String _spacer() => '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>';

  String _line(String label, String value) =>
      '<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(label)}: </w:t></w:r>'
      '<w:r><w:t xml:space="preserve">${_xmlEscape(value)}</w:t></w:r></w:p>';

  String _paragraph(String text) =>
      '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr>'
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

  static const _corePropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties '
      'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>Registration Confirmation</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';
}
