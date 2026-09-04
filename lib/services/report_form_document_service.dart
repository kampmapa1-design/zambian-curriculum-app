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

  /// Only populated for a [ReportClass.isContinuousAssessment] class — the
  /// real Continuous Assessment Test and End-of-Term Exam components each
  /// (non-composite) subject's [scores] entry was computed from. Both maps
  /// stay empty for a standalone-test class; [_subjectsTable] renders the
  /// simple layout (no separate Mid/End columns) in that case.
  final Map<int, double?> caTestScores;
  final Map<int, double?> caExamScores;

  /// Keyed by subject id — this learner's competition-ranked position
  /// WITHIN that one subject (see
  /// [ReportClassRepository.subjectPositions]), not the whole-class
  /// aggregate [classPosition] below. Added 2026-09-04, per explicit
  /// request, matching a real uploaded report form template's own
  /// per-subject "Position in Class" column. Null for a subject this
  /// learner has no score in yet.
  final Map<int, int?> subjectPositions;

  /// Keyed by subject id — that subject's teacher name, entered once via
  /// Manage Subjects and reused for every learner (see
  /// SubjectTeacherRepository). Added 2026-09-04, per explicit request.
  /// Null/blank where no name has been entered — left as a blank cell
  /// rather than a guess.
  final Map<int, String?> teacherNames;

  final int? classPosition;
  final int classSize;
  final String attendanceText;

  const ReportFormMailMergeData({
    required this.reportClass,
    required this.learner,
    required this.subjects,
    required this.scores,
    required this.comments,
    this.caTestScores = const {},
    this.caExamScores = const {},
    this.subjectPositions = const {},
    this.teacherNames = const {},
    this.classPosition,
    required this.classSize,
    this.attendanceText = '',
  });

  /// Every real (non-null) score entered for this learner — the basis for
  /// [_ReportFormLayout]'s summary section. Never guesses a missing
  /// subject's score as zero; a subject with nothing entered yet simply
  /// isn't counted in the average, same "don't guess a missing part" rule
  /// used everywhere else in this pipeline.
  List<double> get enteredScores => [for (final s in subjects) if (scores[s.id] case final v?) v];

  double? get averageScore => enteredScores.isEmpty ? null : enteredScores.reduce((a, b) => a + b) / enteredScores.length;

  /// The real Zambian secondary-school "Score in the Best (6) Subjects"
  /// convention (2026-09-04, per explicit request, matching a real
  /// uploaded report form template) — adapted honestly to this app's own
  /// percentage grading rather than pretending to replicate the separate
  /// ECZ 1-9 points-aggregate system this app has no data to compute: the
  /// average percentage across whichever 6 (or fewer, if this learner has
  /// under 6 scored subjects) subjects scored highest. Null with fewer
  /// than 1 entered score.
  double? get bestSixAverage {
    if (enteredScores.isEmpty) return null;
    final sorted = [...enteredScores]..sort((a, b) => b.compareTo(a));
    final best = sorted.take(6).toList();
    return best.reduce((a, b) => a + b) / best.length;
  }
}

/// Report Form Pipeline, Stage 9 (the template) + Stage 10 (mail-merge
/// generation) + Stage 12 (embedding a Head Teacher signature image) — an
/// **original** report form layout built fresh from standard Zambian
/// secondary-school report form conventions, per the brief's own explicit
/// instruction not to copy any specific existing document's design.
///
/// Redesigned 2026-09-03 (real feedback: the previous layout was a plain
/// labeled-line list with no real visual structure) into an actual form
/// layout — a bordered two-column bio-data grid, a shaded/bold subjects
/// table with proportional column widths (the old hardcoded per-cell width
/// silently overflowed the page once the C.A. layout added extra columns —
/// fixed here by weighting each column against a real, explicit page
/// margin/content width instead), a summary (subject count / average /
/// overall grade), and a grading-key legend built directly from
/// [reportGradeFor]/[reportCommentFor]'s own real bands rather than a
/// second, independently-invented scale. Ruled blank lines are used for
/// anything genuinely hand-completed on a real report form (General
/// Remarks, Next Term Begins) rather than fabricating text nobody wrote —
/// same sourcing-integrity discipline this app applies everywhere else.
///
/// Hand-rolled minimal OOXML, same no-dependency approach as every other
/// document service in this app (see LessonPlanDocumentService/
/// SchemeOfWorkDocumentService) — the one genuinely new piece here is
/// embedding a real image (the Head Teacher's signature, Stage 12) into
/// that same minimal package, which no earlier service in this app has
/// needed before; see [_buildDocumentXml] and the media/relationship parts
/// added only when a signature is given.
class ReportFormDocumentService {
  // A4 portrait, in twips (1/1440 inch): 11906 x 16838. Margins are set
  // explicitly (see [_sectPr]) rather than left to Word's own default —
  // this is what [_contentWidthDxa] weights every table column against, so
  // a table can never silently run past the printable area again.
  static const _pageWidthDxa = 11906;
  static const _marginDxa = 1080; // 0.75in each side
  static const _contentWidthDxa = _pageWidthDxa - (_marginDxa * 2);

  static const _navy = '1F3864';
  static const _lightShade = 'F2F2F2';

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

    // Landscape here (unlike the portrait single-learner report form) —
    // deliberately, this table can run to a dozen subject columns.
    const landscapeWidth = 16838;
    const landscapeContentWidth = landscapeWidth - (_marginDxa * 2);
    final weights = [2.4, for (final _ in subjects) 1.0];

    final buffer = StringBuffer();
    buffer.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>',
    );
    buffer.write(_heading(reportClass.schoolName.toUpperCase()));
    buffer.write(_subheading('BROAD MARK SHEET — ${reportClass.classGrade} — ${reportClass.term}'));
    buffer.write(_spacer());

    final columnWidths = _computeWidths(weights, landscapeContentWidth);
    buffer.write(_tableOpen());
    buffer.write(_tblGrid(columnWidths));
    buffer.write(_weightedTableRow(
      ['Learner', for (final s in subjects) s.name],
      columnWidths,
      bold: true,
      fill: _navy,
      textColor: 'FFFFFF',
    ));
    for (var i = 0; i < learners.length; i++) {
      final learner = learners[i];
      buffer.write(_weightedTableRow(
        [learner.fullName, for (final s in subjects) scoresByLearnerThenSubject[learner.id]?[s.id]?.toStringAsFixed(0) ?? '—'],
        columnWidths,
        fill: i.isOdd ? _lightShade : null,
      ));
    }
    buffer.write('</w:tbl>');
    buffer.write(
      '<w:sectPr><w:pgSz w:w="$landscapeWidth" w:h="$_pageWidthDxa" w:orient="landscape"/>'
      '<w:pgMar w:top="$_marginDxa" w:right="$_marginDxa" w:bottom="$_marginDxa" w:left="$_marginDxa"/>'
      '</w:sectPr></w:body></w:document>',
    );

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
    buffer.write(_ruleLine());
    buffer.write(_spacer());

    buffer.write(_bioGrid(data));
    buffer.write(_spacer());

    buffer.write(_subjectsTable(data));
    buffer.write(_spacer());

    buffer.write(_summarySection(data));
    buffer.write(_spacer());

    buffer.write(_remarksSection());
    buffer.write(_spacer());

    buffer.write(_signatureSection(hasSignature: hasSignature, signedByName: signedByName));
    buffer.write(_spacer());

    buffer.write(_gradingKeyLegend());

    buffer.write(
      '<w:sectPr><w:pgSz w:w="$_pageWidthDxa" w:h="16838"/>'
      '<w:pgMar w:top="$_marginDxa" w:right="$_marginDxa" w:bottom="$_marginDxa" w:left="$_marginDxa"/>'
      '</w:sectPr></w:body></w:document>',
    );
    return buffer.toString();
  }

  String _heading(String text) =>
      '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="60"/></w:pPr>'
      '<w:r><w:rPr><w:rFonts w:ascii="Cambria" w:hAnsi="Cambria"/><w:b/><w:sz w:val="34"/></w:rPr>'
      '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';

  String _subheading(String text) =>
      '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="120"/></w:pPr>'
      '<w:r><w:rPr><w:rFonts w:ascii="Cambria" w:hAnsi="Cambria"/><w:sz w:val="24"/></w:rPr>'
      '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';

  /// A thin horizontal rule under the heading — a paragraph with only a
  /// bottom border, no text — the standard OOXML way to draw a plain line
  /// without a table.
  String _ruleLine() => '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="12" w:space="1" w:color="$_navy"/></w:pBdr>'
      '<w:spacing w:after="120"/></w:pPr></w:p>';

  String _spacer() => '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>';

  String _bodyRun(String text, {bool bold = false}) =>
      '<w:r><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/>${bold ? '<w:b/>' : ''}</w:rPr>'
      '<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r>';

  /// Learner/class bio-data as a real 2-column form grid (borderless — just
  /// for alignment) instead of a long single-column list of labeled lines,
  /// so the printed page actually reads like a form rather than a memo.
  String _bioGrid(ReportFormMailMergeData data) {
    final bestSix = data.bestSixAverage;
    final rows = <List<(String, String)>>[
      [('Learner Name', data.learner.fullName), ('Class', data.reportClass.classGrade)],
      [
        ('Term', data.reportClass.term),
        (
          'Position in Class',
          data.classPosition == null ? 'Not yet ranked' : '${data.classPosition} out of ${data.classSize}',
        ),
      ],
      [
        ('Attendance', data.attendanceText.isEmpty ? '—' : data.attendanceText),
        ('Total Number in Class', '${data.classSize}'),
      ],
      [
        ('No. of Subjects', '${data.subjects.length}'),
        ('Score in Best 6 Subjects', bestSix == null ? '—' : '${bestSix.toStringAsFixed(1)}%'),
      ],
      if (data.reportClass.isContinuousAssessment && data.reportClass.hasConfirmedCaWeights)
        [
          (
            'C.A. Weighting',
            '${data.reportClass.caTestWeightPercent}% Test / ${data.reportClass.caExamWeightPercent}% Exam',
          ),
          ('', ''),
        ],
    ];

    final halfWidth = (_contentWidthDxa / 2).round();
    final buffer = StringBuffer('<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
        '<w:top w:val="none" w:sz="0" w:space="0"/><w:left w:val="none" w:sz="0" w:space="0"/>'
        '<w:bottom w:val="none" w:sz="0" w:space="0"/><w:right w:val="none" w:sz="0" w:space="0"/>'
        '<w:insideH w:val="none" w:sz="0" w:space="0"/><w:insideV w:val="none" w:sz="0" w:space="0"/>'
        '</w:tblBorders></w:tblPr>');
    buffer.write(_tblGrid([halfWidth, _contentWidthDxa - halfWidth]));
    for (final row in rows) {
      buffer.write('<w:tr>');
      for (final (label, value) in row) {
        buffer.write('<w:tc><w:tcPr><w:tcW w:w="$halfWidth" w:type="dxa"/></w:tcPr><w:p>');
        if (label.isNotEmpty) {
          buffer.write(_bodyRun('$label: ', bold: true));
          buffer.write(_bodyRun(value));
        }
        buffer.write('</w:p></w:tc>');
      }
      buffer.write('</w:tr>');
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  String _tableOpen() => '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
      '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
      '</w:tblBorders></w:tblPr>';

  /// The subjects table — matches a real report form template's own
  /// column set (2026-09-04, per explicit request: "switch the app's
  /// report form to this layout"): Subject, Mid/End (C.A. classes only)
  /// or a single Score (standalone classes), Final %, Position in Class
  /// (per-subject — see [ReportFormMailMergeData.subjectPositions]),
  /// Grade, Subject Teacher's Name, Comment. One row per real subject,
  /// never capped (see [ReportFormMailMergeData.subjects], loaded in full
  /// by the caller via ReportClassRepository.listSubjects), shaded/bold
  /// header, alternating row shading. Column widths are weighted
  /// proportionally against a real, explicit content width (see
  /// [_contentWidthDxa]) rather than a flat hardcoded width per cell —
  /// the old flat width silently overflowed the page once the C.A.
  /// layout added extra columns.
  String _subjectsTable(ReportFormMailMergeData data) {
    final isCa = data.reportClass.isContinuousAssessment;
    final headers = isCa
        ? ['Subject', 'Mid', 'End', 'Final (%)', 'Position', 'Grade', "Teacher's Name", 'Comment']
        : ['Subject', 'Score (%)', 'Position', 'Grade', "Teacher's Name", 'Comment'];
    final weights = isCa ? [2.8, 0.9, 0.9, 1.1, 1.0, 0.8, 2.2, 2.8] : [3.0, 1.1, 1.0, 0.8, 2.4, 3.2];
    final columnWidths = _computeWidths(weights, _contentWidthDxa);

    final buffer = StringBuffer(_tableOpen());
    buffer.write(_tblGrid(columnWidths));
    buffer.write(_weightedTableRow(headers, columnWidths, bold: true, fill: _navy, textColor: 'FFFFFF'));

    for (var i = 0; i < data.subjects.length; i++) {
      final subject = data.subjects[i];
      final score = data.scores[subject.id];
      final position = data.subjectPositions[subject.id];
      final teacher = data.teacherNames[subject.id] ?? '';
      final fill = i.isOdd ? _lightShade : null;
      final cells = isCa
          ? [
              subject.name,
              data.caTestScores[subject.id]?.toStringAsFixed(0) ?? '—',
              data.caExamScores[subject.id]?.toStringAsFixed(0) ?? '—',
              score?.toStringAsFixed(0) ?? '—',
              position == null ? '—' : '$position',
              score == null ? '—' : reportGradeFor(score),
              teacher,
              data.comments[subject.id] ?? '',
            ]
          : [
              subject.name,
              score?.toStringAsFixed(0) ?? '—',
              position == null ? '—' : '$position',
              score == null ? '—' : reportGradeFor(score),
              teacher,
              data.comments[subject.id] ?? '',
            ];
      buffer.write(_weightedTableRow(cells, columnWidths, fill: fill));
    }
    buffer.write('</w:tbl>');
    return buffer.toString();
  }

  /// Number of subjects / class average / overall grade — computed
  /// straight from [ReportFormMailMergeData.enteredScores]/[averageScore],
  /// never fabricated: a class with no scores entered yet shows '—'
  /// rather than a misleading 0%.
  String _summarySection(ReportFormMailMergeData data) {
    final average = data.averageScore;
    final buffer = StringBuffer();
    buffer.write('<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>');
    buffer.write(_bodyRun('Summary', bold: true));
    buffer.write('</w:p>');
    buffer.write(_bioRow('Subjects with a score entered', '${data.enteredScores.length} of ${data.subjects.length}'));
    buffer.write(_bioRow('Average', average == null ? '—' : '${average.toStringAsFixed(1)}%'));
    buffer.write(_bioRow('Overall Grade', average == null ? '—' : reportGradeFor(average)));
    return buffer.toString();
  }

  String _bioRow(String label, String value) =>
      '<w:p><w:pPr><w:spacing w:after="20"/></w:pPr>${_bodyRun('$label: ', bold: true)}${_bodyRun(value)}</w:p>';

  /// Blank ruled lines for whatever a real report form is always
  /// hand-completed for after printing — never fabricated text, matching
  /// this app's own sourcing-integrity discipline extended to document
  /// generation: nothing here claims a remark or a date that was never
  /// actually given.
  String _remarksSection() {
    final buffer = StringBuffer();
    buffer.write('<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>');
    buffer.write(_bodyRun("Class Teacher's General Remarks:", bold: true));
    buffer.write('</w:p>');
    buffer.write(_ruledBlankLine());
    buffer.write(_ruledBlankLine());
    buffer.write(_spacer());
    buffer.write('<w:p>');
    buffer.write(_bodyRun('Next Term Begins: ', bold: true));
    buffer.write(_bodyRun('________________________________'));
    buffer.write('</w:p>');
    return buffer.toString();
  }

  String _ruledBlankLine() => '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:space="1" w:color="808080"/></w:pBdr>'
      '<w:spacing w:after="160"/></w:pPr></w:p>';

  String _signatureSection({required bool hasSignature, String? signedByName}) {
    final buffer = StringBuffer();
    buffer.write('<w:p>${_bodyRun('Class / Subject Teacher: ', bold: true)}${_bodyRun('________________________')}</w:p>');
    buffer.write(_spacer());
    buffer.write('<w:p>${_bodyRun('Head Teacher / Deputy: ', bold: true)}</w:p>');
    if (hasSignature) {
      buffer.write(_signatureImageParagraph());
      buffer.write('<w:p>${_bodyRun('Approved by: ', bold: true)}${_bodyRun(signedByName ?? '')}</w:p>');
    } else {
      buffer.write(_spacer());
      buffer.write('<w:p>${_bodyRun('Signature: ', bold: true)}${_bodyRun('________________________')}</w:p>');
    }
    return buffer.toString();
  }

  /// A small legend explaining the Grade column — built directly from
  /// [reportGradeFor]/[reportCommentFor]'s own real, fixed bands (the
  /// single source of truth every grade on this report was computed
  /// from), never a second, independently-invented scale.
  String _gradingKeyLegend() {
    const bands = [
      ('A', '75–100', 'Outstanding'),
      ('B+', '70–74', 'Brilliant'),
      ('B', '60–69', 'Meritorious'),
      ('C+', '55–59', 'Commendable'),
      ('C', '50–54', 'Average'),
      ('D', '40–49', 'Must improve'),
      ('F', '0–39', 'More focus needed'),
    ];
    final buffer = StringBuffer();
    buffer.write('<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>${_bodyRun('Grading Key', bold: true)}</w:p>');
    buffer.write('<w:p><w:pPr><w:spacing w:after="0"/></w:pPr>');
    buffer.write(_bodyRun(bands.map((b) => '${b.$1} (${b.$2}) ${b.$3}').join('   ·   ')));
    buffer.write('</w:p>');
    return buffer.toString();
  }

  /// Turns column [weights] into real dxa widths summing to
  /// [contentWidthDxa] — computed once per table and reused for both the
  /// required `<w:tblGrid>` declaration and every row's own `<w:tcW>`, so
  /// the two can never drift apart (see [_tblGrid]'s own doc comment on
  /// why that element has to exist at all).
  List<int> _computeWidths(List<double> weights, int contentWidthDxa) {
    final totalWeight = weights.fold<double>(0, (a, b) => a + b);
    if (totalWeight <= 0) {
      return [for (var i = 0; i < weights.length; i++) (contentWidthDxa / weights.length).round()];
    }
    return [for (final w in weights) (w / totalWeight * contentWidthDxa).round()];
  }

  /// `<w:tblGrid>` — a REQUIRED child of `<w:tbl>` per the OOXML schema
  /// (declares each column's width at the table level, separate from the
  /// per-cell `<w:tcW>` every row also carries). Real, found bug
  /// (2026-09-03): every hand-rolled table in this file omitted it since
  /// this pipeline's very first version — desktop Word tolerates the
  /// omission by silently recomputing column layout on its own, but a
  /// stricter reader (confirmed here via a real python-docx round-trip,
  /// not just `flutter analyze`) rejects the table outright, and other
  /// real-world DOCX viewers (mobile Word, WPS Office, Google Docs) are
  /// exactly the kind of "less forgiving than desktop Word" readers where
  /// an invalid table like this could easily explain a report showing
  /// only some of a learner's real subjects.
  String _tblGrid(List<int> widths) =>
      '<w:tblGrid>${widths.map((w) => '<w:gridCol w:w="$w"/>').join()}</w:tblGrid>';

  /// One table row using pre-computed [widths] (see [_computeWidths]) —
  /// always the same widths the table's own `<w:tblGrid>` declares, never
  /// recomputed per row.
  String _weightedTableRow(
    List<String> cells,
    List<int> widths, {
    bool bold = false,
    String? fill,
    String? textColor,
  }) {
    final buffer = StringBuffer('<w:tr>');
    for (var i = 0; i < cells.length; i++) {
      final width = i < widths.length ? widths[i] : widths.isEmpty ? 0 : widths.last;
      final shd = fill != null ? '<w:shd w:val="clear" w:color="auto" w:fill="$fill"/>' : '';
      final colorTag = textColor != null ? '<w:color w:val="$textColor"/>' : '';
      buffer.write(
        '<w:tc><w:tcPr><w:tcW w:w="$width" w:type="dxa"/>$shd</w:tcPr>'
        '<w:p><w:r><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="20"/>'
        '$colorTag${bold ? '<w:b/>' : ''}</w:rPr>'
        '<w:t xml:space="preserve">${_xmlEscape(cells[i])}</w:t></w:r></w:p></w:tc>',
      );
    }
    buffer.write('</w:tr>');
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
