import 'package:pdf/widgets.dart' as pw;

import '../models/marking_scheme.dart';

/// Renders a "Reference: Assessment Content From Your Marking Keys"
/// section — appended to generated Lesson Plans and Schemes of Work when
/// a locally-stored marking key's subject matches. Entirely offline (the
/// marking key data is already on-device via MarkingSchemeRepository, no
/// network call). Purely additive: renders nothing when [relatedKeys] is
/// empty, so a subject with no uploaded marking key produces exactly the
/// same document as before this feature existed.
///
/// A sample of each matching key's real questions/expected answers is
/// shown (capped, not the whole key) — real, sourced content the teacher
/// themselves uploaded, never AI-invented, letting the plan/scheme be
/// informed by what's actually been assessed on this subject.
const int relatedMarkingKeyQuestionSampleSize = 4;

List<pw.Widget> buildRelatedMarkingKeyPdfSection(List<MarkingScheme> relatedKeys) {
  if (relatedKeys.isEmpty) return const [];
  final widgets = <pw.Widget>[
    pw.SizedBox(height: 16),
    pw.Divider(),
    pw.Text(
      'Reference: Assessment Content From Your Marking Keys',
      style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
    ),
    pw.SizedBox(height: 4),
    pw.Text(
      'Sample content from marking keys you\'ve uploaded for this subject, to inform planning — not part '
      'of the generated plan/scheme itself.',
      style: pw.TextStyle(fontSize: 8.5, fontStyle: pw.FontStyle.italic),
    ),
  ];
  for (final scheme in relatedKeys) {
    widgets.add(pw.SizedBox(height: 8));
    widgets.add(pw.Text(scheme.title, style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold)));
    for (final q in scheme.questions.take(relatedMarkingKeyQuestionSampleSize)) {
      widgets.add(pw.Padding(
        padding: const pw.EdgeInsets.only(top: 3, left: 8),
        child: pw.Text('${q.label}: ${q.expectedAnswerOrKeywords}', style: const pw.TextStyle(fontSize: 9)),
      ));
    }
  }
  return widgets;
}

String buildRelatedMarkingKeyDocxSection(List<MarkingScheme> relatedKeys) {
  if (relatedKeys.isEmpty) return '';
  final buffer = StringBuffer();
  buffer.write(
    '<w:p><w:pPr><w:spacing w:before="240" w:after="80"/></w:pPr>'
    '<w:r><w:rPr><w:b/><w:sz w:val="26"/></w:rPr>'
    '<w:t xml:space="preserve">Reference: Assessment Content From Your Marking Keys</w:t></w:r></w:p>',
  );
  buffer.write(
    '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr>'
    '<w:r><w:rPr><w:i/></w:rPr>'
    '<w:t xml:space="preserve">Sample content from marking keys you\'ve uploaded for this subject, to inform '
    'planning — not part of the generated plan/scheme itself.</w:t></w:r></w:p>',
  );
  for (final scheme in relatedKeys) {
    buffer.write(
      '<w:p><w:pPr><w:spacing w:before="120" w:after="60"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr>'
      '<w:t xml:space="preserve">${_xmlEscape(scheme.title)}</w:t></w:r></w:p>',
    );
    for (final q in scheme.questions.take(relatedMarkingKeyQuestionSampleSize)) {
      buffer.write(
        '<w:p><w:pPr><w:ind w:left="360"/><w:spacing w:after="60"/></w:pPr>'
        '<w:r><w:t xml:space="preserve">${_xmlEscape('${q.label}: ${q.expectedAnswerOrKeywords}')}</w:t></w:r></w:p>',
      );
    }
  }
  return buffer.toString();
}

String _xmlEscape(String input) => input
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
