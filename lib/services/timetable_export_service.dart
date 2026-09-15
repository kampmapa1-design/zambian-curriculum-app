import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/school.dart';
import '../models/timetable.dart';
import 'school_branding_service.dart';

const _kWeekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class _PdfSection {
  const _PdfSection({required this.title, required this.assignments, required this.cellSubtitle});
  final String title;
  final List<TimetableAssignment> assignments;
  final String Function(TimetableAssignment) cellSubtitle;
}

/// Timetable Generation, Stage 10 (export) and Stage 12 (added
/// 2026-09-14 — "school-branded, pin-ready export"). Every PDF page
/// carries the school's name, and its logo too when one is stored (see
/// SchoolBrandingService — "if one is stored" is exactly what
/// [SchoolBrandingService.getLogoBytes] returning null vs bytes means),
/// so a page is self-identifying once it leaves the app via Export,
/// Pin to Staffroom, or Share to WhatsApp. Builds bytes directly (no
/// `path_provider`/temp-file step) since this is reached from both the
/// web dashboard (no device filesystem) and mobile.
class TimetableExportService {
  TimetableExportService({SchoolBrandingService? brandingService}) : _brandingService = brandingService ?? SchoolBrandingService();

  final SchoolBrandingService _brandingService;

  String _safeName(String name) => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  /// One page per class — the original whole-school export.
  Future<Uint8List> buildWholeSchoolPdfBytes({
    required School school,
    required GeneratedTimetable generated,
    required TimetableConfig config,
    required Map<String, String> teacherNameByUid,
  }) async {
    final byClass = <String, List<TimetableAssignment>>{};
    final classNames = <String, String>{};
    for (final a in generated.assignments) {
      (byClass[a.classId] ??= []).add(a);
      classNames[a.classId] = a.className;
    }
    final classIds = byClass.keys.toList()..sort((a, b) => (classNames[a] ?? '').compareTo(classNames[b] ?? ''));
    final sections = [
      for (final classId in classIds)
        _PdfSection(
          title: classNames[classId] ?? classId,
          assignments: byClass[classId]!,
          cellSubtitle: (a) => teacherNameByUid[a.teacherUid] ?? a.teacherUid,
        ),
    ];
    return _buildPdf(school: school, config: config, sections: sections);
  }

  Future<void> exportWholeSchoolPdf({
    required School school,
    required GeneratedTimetable generated,
    required TimetableConfig config,
    required Map<String, String> teacherNameByUid,
  }) async {
    final bytes = await buildWholeSchoolPdfBytes(school: school, generated: generated, config: config, teacherNameByUid: teacherNameByUid);
    await _saveFile(bytes: bytes, name: '${_safeName(school.name)}_timetable', extension: 'pdf', mimeType: MimeType.pdf);
  }

  /// Stages 11 & 12 — one class's grid, or one teacher's combined grid
  /// (across every class they teach), each on a single page.
  Future<Uint8List> buildScopedPdfBytes({
    required School school,
    required String scopeTitle,
    required List<TimetableAssignment> assignments,
    required TimetableConfig config,
    required String Function(TimetableAssignment) cellSubtitle,
  }) => _buildPdf(school: school, config: config, sections: [_PdfSection(title: scopeTitle, assignments: assignments, cellSubtitle: cellSubtitle)]);

  Future<void> exportClassPdf({
    required School school,
    required String className,
    required List<TimetableAssignment> assignments,
    required TimetableConfig config,
    required Map<String, String> teacherNameByUid,
  }) async {
    final bytes = await buildScopedPdfBytes(
      school: school,
      scopeTitle: className,
      assignments: assignments,
      config: config,
      cellSubtitle: (a) => teacherNameByUid[a.teacherUid] ?? a.teacherUid,
    );
    await _saveFile(bytes: bytes, name: '${_safeName(school.name)}_${_safeName(className)}_timetable', extension: 'pdf', mimeType: MimeType.pdf);
  }

  Future<void> exportTeacherPdf({
    required School school,
    required String teacherName,
    required List<TimetableAssignment> assignments,
    required TimetableConfig config,
  }) async {
    final bytes = await buildScopedPdfBytes(
      school: school,
      scopeTitle: teacherName,
      assignments: assignments,
      config: config,
      cellSubtitle: (a) => a.className,
    );
    await _saveFile(bytes: bytes, name: '${_safeName(school.name)}_${_safeName(teacherName)}_timetable', extension: 'pdf', mimeType: MimeType.pdf);
  }

  Future<void> exportCsv({required School school, required List<TimetableAssignment> assignments, String? scopeLabel}) async {
    final csv = _buildCsv(school, assignments, scopeLabel);
    await _saveFile(
      bytes: Uint8List.fromList(utf8.encode(csv)),
      name: '${_safeName(school.name)}${scopeLabel != null ? '_${_safeName(scopeLabel)}' : ''}_timetable',
      extension: 'csv',
      mimeType: MimeType.csv,
    );
  }

  Future<void> _saveFile({required Uint8List bytes, required String name, required String extension, required MimeType mimeType}) =>
      FileSaver.instance.saveFile(name: name, bytes: bytes, fileExtension: extension, mimeType: mimeType);

  String _buildCsv(School school, List<TimetableAssignment> assignments, String? scopeLabel) {
    final rows = <String>['# ${school.name}${scopeLabel != null ? ' — $scopeLabel' : ''}', 'Class,Day,Period,Subject,Teacher'];
    final sorted = [...assignments]
      ..sort((a, b) {
        final byClass = a.className.compareTo(b.className);
        if (byClass != 0) return byClass;
        final byDay = a.day.compareTo(b.day);
        return byDay != 0 ? byDay : a.period.compareTo(b.period);
      });
    for (final a in sorted) {
      final day = a.day >= 0 && a.day < _kWeekdayLabels.length ? _kWeekdayLabels[a.day] : '${a.day}';
      rows.add('"${a.className}",$day,${a.period + 1},"${a.subjectName}","${a.teacherUid}"');
    }
    return rows.join('\n');
  }

  Future<Uint8List> _buildPdf({required School school, required TimetableConfig config, required List<_PdfSection> sections}) async {
    final logoBytes = await _brandingService.getLogoBytes(school.id);
    final logoImage = logoBytes != null ? pw.MemoryImage(logoBytes) : null;
    final doc = pw.Document();
    final days = config.teachingDaysPerWeek.clamp(0, 7);

    for (final section in sections) {
      final byDayPeriod = {for (final a in section.assignments) '${a.day}_${a.period}': a};
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(24),
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  if (logoImage != null) ...[
                    pw.Container(height: 36, width: 36, child: pw.Image(logoImage)),
                    pw.SizedBox(width: 10),
                  ],
                  pw.Text(school.name, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: PdfColors.grey800)),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Text(section.title, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 12),
              pw.Table(
                border: pw.TableBorder.all(width: 0.5, color: PdfColors.grey400),
                columnWidths: {0: const pw.FlexColumnWidth(0.8), for (var d = 1; d <= days; d++) d: const pw.FlexColumnWidth(2)},
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                    children: [
                      _pdfCell('Period', bold: true),
                      for (var d = 0; d < days; d++) _pdfCell(_kWeekdayLabels[d], bold: true),
                    ],
                  ),
                  for (var p = 0; p < config.periodsPerDay; p++)
                    pw.TableRow(
                      children: [
                        _pdfCell('${p + 1}'),
                        for (var d = 0; d < days; d++) _pdfAssignmentCell(byDayPeriod['${d}_$p'], section.cellSubtitle),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return doc.save();
  }

  pw.Widget _pdfCell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      );

  pw.Widget _pdfAssignmentCell(TimetableAssignment? a, String Function(TimetableAssignment) cellSubtitle) {
    if (a == null) return _pdfCell('');
    return pw.Padding(
      padding: const pw.EdgeInsets.all(4),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(a.subjectName, style: const pw.TextStyle(fontSize: 8.5)),
          pw.Text(cellSubtitle(a), style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
        ],
      ),
    );
  }
}
