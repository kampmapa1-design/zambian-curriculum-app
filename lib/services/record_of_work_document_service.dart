import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/record_of_work.dart';

/// Renders a [RecordOfWorkDraft] as a PDF or Word (.docx) file, entirely
/// on-device — no network, no server round trip. Mirrors
/// [SchemeOfWorkDocumentService]'s approach (landscape, since a Record of
/// Work has several columns) and [LessonPlanDocumentService]'s hand-built
/// OOXML writer for DOCX, for visual and technical consistency with the
/// rest of the app's exports.
class RecordOfWorkDocumentService {
  String _fileBaseName(RecordOfWorkDraft draft) {
    final raw = '${draft.subjectName}_${draft.className}_${draft.period.label}';
    final safe = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'record_of_work' : 'record_of_work_$safe';
  }

  Future<File> _writeToTempFile(String extension, List<int> bytes, RecordOfWorkDraft draft) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, '${_fileBaseName(draft)}.$extension');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _dateRangeLabel(RecordOfWorkDraft draft) {
    String fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    return '${fmt(draft.rangeStart)} — ${fmt(draft.rangeEnd)}';
  }

  // ---------------------------------------------------------------------
  // PDF — landscape, several columns.
  // ---------------------------------------------------------------------

  Future<File> generatePdf(RecordOfWorkTemplate template, RecordOfWorkDraft draft) async {
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        build: (context) => [
          pw.Center(
            child: pw.Text('RECORD OF WORK', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(height: 10),
          _pdfLabeledLine('School', draft.schoolName),
          _pdfLabeledLine('Teacher', draft.teacherName),
          _pdfLabeledLine('Curriculum', draft.curriculumName),
          _pdfLabeledLine('Subject', draft.subjectName),
          _pdfLabeledLine('Class', draft.className),
          _pdfLabeledLine('Period', '${draft.period.label} (${_dateRangeLabel(draft)})'),
          _pdfLabeledLine('Status', draft.status.label),
          pw.SizedBox(height: 12),
          pw.Table(
            border: pw.TableBorder.all(width: 0.5),
            columnWidths: {
              for (var i = 0; i < template.columns.length; i++)
                i: pw.FlexColumnWidth(template.columns[i].id == 'topicLabel' ? 2.2 : 1.2),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [for (final c in template.columns) _pdfHeaderCell(c.label)],
              ),
              for (final row in draft.rows)
                pw.TableRow(children: [for (final c in template.columns) _pdfCell(row.value(c))]),
            ],
          ),
          if (draft.rows.isEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text(
              'No lesson history entries were found for this subject/class in the selected date range.',
              style: const pw.TextStyle(fontSize: 10),
            ),
          ],
        ],
      ),
    );

    final bytes = await doc.save();
    return _writeToTempFile('pdf', bytes, draft);
  }

  pw.Widget _pdfLabeledLine(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 2),
        child: pw.RichText(
          text: pw.TextSpan(
            children: [
              pw.TextSpan(text: '$label: ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
              pw.TextSpan(text: value, style: const pw.TextStyle(fontSize: 10)),
            ],
          ),
        ),
      );

  pw.Widget _pdfHeaderCell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5)),
      );

  pw.Widget _pdfCell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text, style: const pw.TextStyle(fontSize: 8.5)),
      );

  // ---------------------------------------------------------------------
  // DOCX — hand-built minimal OOXML package, same approach as
  // LessonPlanDocumentService/SchemeOfWorkDocumentService.
  // ---------------------------------------------------------------------

  Future<File> generateDocx(RecordOfWorkTemplate template, RecordOfWorkDraft draft) async {
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
    addXml('word/document.xml', _buildDocumentXml(template, draft));

    final zipped = ZipEncoder().encode(archive);
    return _writeToTempFile('docx', zipped, draft);
  }

  String _buildDocumentXml(RecordOfWorkTemplate template, RecordOfWorkDraft draft) {
    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );

    buffer.write(_docxHeading('RECORD OF WORK', size: 32, center: true));
    buffer.write(_docxLabeledParagraph('School', draft.schoolName));
    buffer.write(_docxLabeledParagraph('Teacher', draft.teacherName));
    buffer.write(_docxLabeledParagraph('Curriculum', draft.curriculumName));
    buffer.write(_docxLabeledParagraph('Subject', draft.subjectName));
    buffer.write(_docxLabeledParagraph('Class', draft.className));
    buffer.write(_docxLabeledParagraph('Period', '${draft.period.label} (${_dateRangeLabel(draft)})'));
    buffer.write(_docxLabeledParagraph('Status', draft.status.label));

    buffer.write(_docxTable(template, draft));

    if (draft.rows.isEmpty) {
      buffer.write(_docxLabeledParagraph(
        'Note',
        'No lesson history entries were found for this subject/class in the selected date range.',
      ));
    }

    buffer.write('<w:sectPr><w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/></w:sectPr></w:body></w:document>');
    return buffer.toString();
  }

  String _docxHeading(String text, {int size = 24, bool center = false}) {
    final jc = center ? '<w:jc w:val="center"/>' : '';
    return '<w:p><w:pPr>$jc<w:spacing w:before="200" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
  }

  String _docxLabeledParagraph(String label, String value) {
    return '<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>'
        '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(label)}: </w:t></w:r>'
        '<w:r><w:t xml:space="preserve">${_xmlEscape(value)}</w:t></w:r></w:p>';
  }

  String _docxTable(RecordOfWorkTemplate template, RecordOfWorkDraft draft) {
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
    buffer.write(_docxTableRow([for (final c in template.columns) c.label], bold: true));
    for (final row in draft.rows) {
      buffer.write(_docxTableRow([for (final c in template.columns) row.value(c)]));
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  String _docxTableRow(List<String> cells, {bool bold = false}) {
    final buffer = StringBuffer('<w:tr>');
    for (final cell in cells) {
      final rPr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
      final lines = cell.isEmpty ? [''] : cell.split('\n');
      buffer.write('<w:tc><w:tcPr><w:tcW w:w="1300" w:type="dxa"/></w:tcPr>');
      for (final line in lines) {
        buffer.write('<w:p><w:r>$rPr<w:t xml:space="preserve">${_xmlEscape(line)}</w:t></w:r></w:p>');
      }
      buffer.write('</w:tc>');
    }
    buffer.write('</w:tr>');
    return buffer.toString();
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
      '<dc:title>Record of Work</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';
}
