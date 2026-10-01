import 'dart:convert';

import 'package:archive/archive.dart';

import '../models/lesson_plan.dart';

/// Bundled copy of the official OBC lesson plan template (supplied by the
/// user, 2026-09-26). Its styles, fonts, page setup and coat-of-arms image
/// are used exactly as-is — only the body is regenerated per lesson.
const kObcLessonPlanTemplateAsset = 'assets/lesson_plan_templates/obc_lesson_plan_template.docx';

/// Fills the official OBC template with [draft], for both OBC layouts:
/// Natural Sciences & Mathematics (5-column progression table) and Social
/// Sciences (4-column: no CONTENT / LEARNING POINTS column, last column
/// "Assessment Criteria") — see [LessonPlanTemplate.progressionContentMode].
///
/// The output package IS the template package with `word/document.xml`
/// replaced (and `docProps/core.xml` reset), so the header blocks, the ten
/// numbered sections' typography, table shading (EDEDED), sizes and page
/// margins are all the template's own. Returns the .docx bytes.
List<int> buildObcLessonPlanDocx({
  required List<int> templateBytes,
  required LessonPlanTemplate template,
  required LessonPlanDraft draft,
}) {
  final source = ZipDecoder().decodeBytes(templateBytes);
  final documentFile = source.findFile('word/document.xml');
  if (documentFile == null) throw const FormatException('OBC template has no word/document.xml');
  final original = utf8.decode(documentFile.content);

  final bodyOpen = original.indexOf('<w:body>');
  final sectStart = original.lastIndexOf('<w:sectPr');
  final bodyClose = original.indexOf('</w:body>');
  final drawingAt = original.indexOf('<w:drawing>');
  if (bodyOpen < 0 || sectStart < 0 || bodyClose < 0 || drawingAt < 0) {
    throw const FormatException('OBC template document.xml is not in the expected shape');
  }
  final logoStart = original.lastIndexOf('<w:p ', drawingAt);
  final logoEnd = original.indexOf('</w:p>', drawingAt) + '</w:p>'.length;

  final xml = StringBuffer()
    ..write(original.substring(0, bodyOpen + '<w:body>'.length))
    ..write(_scaledLogo(original.substring(logoStart, logoEnd)))
    ..write(_centered('REPUBLIC OF ZAMBIA', size: 30))
    ..write(_centered('Ministry of Education', size: 24))
    ..write(_centered('Senior Secondary School Lesson Plan', size: 24))
    ..write(_headerTables(draft))
    ..write('<w:p/>');

  for (final field in _sectionFields(template, 'planning')) {
    xml.write(_numberedSection(field, draft.value(field.id)));
  }
  xml
    ..write(_heading('7. LESSON DEVELOPMENT / PROGRESSION', spaceAfter: null))
    ..write(_progressionTable(template, draft));
  for (final field in _sectionFields(template, 'evaluation')) {
    xml.write(_numberedSection(field, draft.value(field.id)));
  }
  xml
    ..write(original.substring(sectStart, bodyClose))
    ..write('</w:body></w:document>');

  final out = Archive();
  for (final file in source.files) {
    if (!file.isFile) continue;
    switch (file.name) {
      case 'word/document.xml':
        out.addFile(ArchiveFile.bytes(file.name, utf8.encode(xml.toString())));
      case 'docProps/core.xml':
        out.addFile(ArchiveFile.bytes(file.name, utf8.encode(_coreProps)));
      default:
        out.addFile(ArchiveFile.bytes(file.name, file.content));
    }
  }
  return ZipEncoder().encode(out);
}

/// Shrinks the coat-of-arms drawing to a typical Zambian government
/// letterhead size (2026-09-28, per explicit request: "the coat of arms
/// seems to be bigger than usual on the lesson plan... resize it to the
/// usual size used on word documents"). The as-supplied template embeds it
/// at ~0.99in x 0.86in (`wp:extent cx="902335" cy="784614"`, EMUs — 914400
/// EMU per inch) — noticeably larger than the ~0.55-0.6in crest typical of
/// an official Zambian letterhead. Scaled down by [_logoScale] (both the
/// `wp:extent` the document layout reserves and the inner `a:ext` the
/// picture itself is drawn at, kept in lockstep so the image isn't
/// stretched/cropped), rather than swapping in a different image — the
/// bundled artwork itself is fine, it was just placed too large.
const _logoScale = 0.6;

final _extentPattern = RegExp(r'(wp:extent|a:ext) cx="(\d+)" cy="(\d+)"');

String _scaledLogo(String paragraphXml) => paragraphXml.replaceAllMapped(_extentPattern, (m) {
      final cx = (int.parse(m.group(2)!) * _logoScale).round();
      final cy = (int.parse(m.group(3)!) * _logoScale).round();
      return '${m.group(1)} cx="$cx" cy="$cy"';
    });

Iterable<LessonPlanFieldDef> _sectionFields(LessonPlanTemplate template, String sectionId) =>
    template.sections.where((s) => s.id == sectionId).expand((s) => s.fields);

const _coreProps = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<cp:coreProperties '
    'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>Lesson Plan</dc:title>'
    '<dc:creator>Smart Teacher</dc:creator>'
    '</cp:coreProperties>';

String _esc(String input) => input
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _centered(String text, {required int size}) => '<w:p><w:pPr><w:spacing w:after="0"/><w:jc w:val="center"/></w:pPr>'
    '<w:r><w:rPr><w:b/><w:sz w:val="$size"/></w:rPr><w:t>${_esc(text)}</w:t></w:r></w:p>';

/// Runs for [lines] inside ONE paragraph, separated by line breaks — the
/// template's own way of stacking text in a cell/section.
String _runs(List<String> lines, {required int size, bool bold = false}) {
  final rPr = '<w:rPr>${bold ? '<w:b/>' : ''}<w:sz w:val="$size"/></w:rPr>';
  final buffer = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final text = lines[i];
    buffer.write('<w:r>$rPr${i > 0 ? '<w:br/>' : ''}');
    if (text.isNotEmpty) buffer.write('<w:t xml:space="preserve">${_esc(text)}</w:t>');
    buffer.write('</w:r>');
  }
  return buffer.toString();
}

const _tblPr = '<w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/><w:jc w:val="center"/>'
    '<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0" '
    'w:noHBand="0" w:noVBand="1"/></w:tblPr>';

String _cell(int width, List<String> lines, {required int size, bool shaded = false, bool bold = false, bool center = false}) {
  final shading = shaded ? '<w:shd w:val="clear" w:color="auto" w:fill="EDEDED"/>' : '';
  final vAlign = center ? '<w:vAlign w:val="center"/>' : '';
  final content = lines.isEmpty ? '<w:p/>' : '<w:p>${_runs(lines, size: size, bold: bold)}</w:p>';
  return '<w:tc><w:tcPr><w:tcW w:w="$width" w:type="dxa"/>$shading$vAlign</w:tcPr>$content</w:tc>';
}

String _row(List<String> cells, {int? minHeight}) {
  final height = minHeight == null ? '' : '<w:trHeight w:val="$minHeight" w:hRule="atLeast"/>';
  return '<w:tr><w:trPr>$height<w:jc w:val="center"/></w:trPr>${cells.join()}</w:tr>';
}

List<String> _lines(String value) => value.trim().isEmpty ? const [] : value.split('\n');

String _grid(List<int> widths) => '<w:tblGrid>${[for (final w in widths) '<w:gridCol w:w="$w"/>'].join()}</w:tblGrid>';

/// The two header blocks: NAME OF TEACHER / GRADE/CLASS / DATE across the
/// top, then NAME OF SCHOOL / SUBJECT / TOPIC / SUB-TOPIC / DURATION/TIME.
String _headerTables(LessonPlanDraft draft) {
  const top = [('NAME OF TEACHER', 'teacherName'), ('GRADE/CLASS', 'className'), ('DATE', 'date')];
  const details = [
    ('NAME OF SCHOOL', 'school'),
    ('SUBJECT', 'subject'),
    ('TOPIC', 'topic'),
    ('SUB-TOPIC', 'subTopic'),
    ('DURATION/TIME', 'duration'),
  ];
  final first = StringBuffer('<w:tbl>$_tblPr${_grid([3600, 3600, 3600])}')
    ..write(_row([for (final (label, _) in top) _cell(3600, [label], size: 17, shaded: true, bold: true, center: true)]))
    ..write(_row([for (final (_, id) in top) _cell(3600, _lines(draft.value(id)), size: 18, center: true)]))
    ..write('</w:tbl>');

  final second = StringBuffer('<w:tbl>$_tblPr${_grid([3686, 7114])}');
  for (final (label, id) in details) {
    second
      ..write('<w:tr><w:trPr><w:jc w:val="center"/></w:trPr>')
      ..write(_cell(3686, [label], size: 17, shaded: true, bold: true))
      ..write(_cell(7114, _lines(draft.value(id)), size: 18))
      ..write('</w:tr>');
  }
  second.write('</w:tbl>');
  return '$first<w:p/>$second';
}

String _heading(String text, {int? spaceAfter = 20}) {
  final pPr = spaceAfter == null ? '' : '<w:pPr><w:spacing w:after="$spaceAfter"/></w:pPr>';
  return '<w:p>$pPr<w:r><w:rPr><w:b/><w:sz w:val="18"/></w:rPr><w:t>${_esc(text)}</w:t></w:r></w:p>';
}

/// One numbered section: bold heading, then either the teacher's text or —
/// when empty — the template's own ruled blank lines to write on.
String _numberedSection(LessonPlanFieldDef field, String value) {
  final lines = value.trim().isEmpty
      ? List.filled(field.blankLines > 0 ? field.blankLines : 1, '_' * 80)
      : value.split('\n');
  return '${_heading(field.label.toUpperCase())}'
      '<w:p><w:pPr><w:spacing w:after="60"/></w:pPr>${_runs(lines, size: 16)}</w:p>';
}

String _progressionTable(LessonPlanTemplate template, LessonPlanDraft draft) {
  final ownColumn = template.hasContentColumn;
  final widths = ownColumn ? List.filled(5, 2160) : List.filled(4, 2700);
  final headers = [
    'STAGE / TIME',
    if (ownColumn) 'CONTENT / LEARNING POINTS',
    'TEACHERS’ ROLE',
    'LEARNERS’ ROLE',
    template.assessmentColumnLabel,
  ];

  final buffer = StringBuffer('<w:tbl>$_tblPr${_grid(widths)}')
    ..write(_row([
      for (var i = 0; i < headers.length; i++) _cell(widths[i], [headers[i]], size: 14, shaded: true, bold: true),
    ]));
  for (final row in draft.progression) {
    final time = row.durationMinutes.trim().isEmpty ? '______' : row.durationMinutes.trim();
    final cells = [
      [row.stage.toUpperCase(), '', 'Time: $time'],
      if (ownColumn) _lines(row.content),
      _lines(row.teacherRole),
      _lines(row.learnersRole),
      _lines(row.assessmentCriteria),
    ];
    buffer.write(_row(
      [for (var i = 0; i < cells.length; i++) _cell(widths[i], cells[i], size: 14)],
      minHeight: 1000,
    ));
  }
  buffer.write('</w:tbl>');
  return buffer.toString();
}
