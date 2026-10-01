/// How many bullet points the Development stage's "CONTENT / LEARNING POINTS"
/// cell carries in the OBC Natural Sciences & Mathematics layout (2026-09-26,
/// per explicit request: "let us say six bulletins based on the actual
/// teaching points ... in the lesson notes").
const kContentColumnPointCount = 6;

/// A single bullet stays a readable line, not a paragraph.
const _pointWordCap = 30;

final _bulletMarker = RegExp(r'^\s*(?:[-•*–·]+|\d+[.)])\s+');
final _sentenceBreak = RegExp(r'(?<=[.!?])\s+');

/// A bullet's text, or '' when it cannot be made a clean one-line point. A
/// sentence longer than [_pointWordCap] words is cut back to its last clause
/// break (comma, semicolon or colon) inside the cap and closed with a full
/// stop — never chopped mid-phrase with an ellipsis; with no usable clause
/// break it is left out rather than shown half-finished.
String _clean(String line) {
  final text = line.replaceFirst(_bulletMarker, '').replaceAll(RegExp(r'\*+'), '').trim();
  final words = text.split(RegExp(r'\s+'));
  if (words.length <= _pointWordCap) return text;
  final prefix = words.take(_pointWordCap).join(' ');
  final cut = [prefix.lastIndexOf(','), prefix.lastIndexOf(';'), prefix.lastIndexOf(':')].reduce((x, y) => x > y ? x : y);
  if (cut <= prefix.length ~/ 2) return '';
  // Don't end on a dangling connective ("..., and").
  var body = prefix.substring(0, cut).trimRight();
  final dangling = RegExp(r'[,;:]?\s*\b(?:and|or|but|as|the|a|an|of|to|at|in)$', caseSensitive: false);
  while (dangling.hasMatch(body)) {
    body = body.replaceFirst(dangling, '').trimRight();
  }
  body = body.replaceFirst(RegExp(r'[,;:]+$'), '');
  return body.split(RegExp(r'\s+')).length >= 4 ? '$body.' : '';
}

int _wordCount(String s) => s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

/// De-duplicated (case-insensitive), order-preserving.
List<String> _unique(Iterable<String> points) {
  final seen = <String>{};
  return [
    for (final p in points)
      if (seen.add(p.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim())) p,
  ];
}

/// Up to [max] teaching points taken from real lesson material [text] (e.g.
/// the on-device subject-content excerpt the lesson notes are also grounded
/// in) — one per sentence, in the order the material makes them. Nothing is
/// invented: a short or empty [text] simply yields fewer points.
///
/// With [relevantTo] (the lesson's own topic/outcome keywords), a sentence
/// must share at least [minKeywordMatches] of them — so a loosely matched
/// excerpt cannot put off-topic facts in the Content column.
List<String> teachingPointsFromText(
  String? text, {
  int max = kContentColumnPointCount,
  Set<String>? relevantTo,
  int minKeywordMatches = 2,
}) {
  if (text == null || text.trim().isEmpty) return const [];
  bool relevant(String sentence) {
    if (relevantTo == null || relevantTo.isEmpty) return true;
    final need = relevantTo.length < minKeywordMatches ? relevantTo.length : minKeywordMatches;
    final words = sentence.toLowerCase().split(RegExp(r'[^a-z0-9]+')).toSet();
    return relevantTo.where(words.contains).length >= need;
  }

  final sentences = [
    for (final line in text.split('\n'))
      for (final sentence in line.split(_sentenceBreak)) _clean(sentence),
  ].where((s) => _wordCount(s) >= 4 && relevant(s));
  return _unique(sentences).take(max).toList();
}

/// Up to [max] teaching points taken from a generated "Lesson Notes"
/// document (bullet format, bullets grouped under short subheadings). Only
/// bullet lines count — subheadings are skipped — and when there are more
/// than [max] they are picked evenly across the notes so every subheading's
/// area is represented rather than just the first few. Empty when the notes
/// have no bullet lines.
List<String> teachingPointsFromNotes(String notes, {int max = kContentColumnPointCount}) {
  final bullets = _unique([
    for (final line in notes.split('\n'))
      if (_bulletMarker.hasMatch(line)) _clean(line),
  ].where((s) => _wordCount(s) >= 3));
  if (bullets.length <= max) return bullets;
  return [for (var i = 0; i < max; i++) bullets[(i * (bullets.length - 1) / (max - 1)).round()]];
}

/// Merges [primary] points with [topUp] points (syllabus competencies) until
/// [max], skipping any already present — so a lesson with rich material shows
/// its material, and a thin one still shows its real syllabus outcomes rather
/// than fewer bullets than it could honestly have.
List<String> topUpPoints(List<String> primary, List<String> topUp, {int max = kContentColumnPointCount}) =>
    _unique([...primary, ...topUp]).take(max).toList();

String bulletLines(List<String> points) => points.map((p) => '•  $p').join('\n');

/// Whether the Development stage's Content cell may be replaced with points
/// from the Lesson Notes: only when it is blank or still EXACTLY the text the
/// app generated — anything the teacher has typed over is never overwritten.
bool contentMayBeReplaced({required String current, required String? autoGenerated}) =>
    current.trim().isEmpty || (autoGenerated != null && current.trim() == autoGenerated.trim());

/// The Development stage never shows fewer than this many points (2026-09-26,
/// per explicit request: "no less than six points under lesson development").
const kMinimumContentPoints = 6;

/// Teaching-move prompts used to complete a thin list — each one is anchored
/// to a REAL syllabus outcome (or the topic itself), so it says what to
/// teach about that subject matter without asserting any fact the app does
/// not have. Ordered so one prompt is spread across every outcome before the
/// next prompt starts.
const _scaffolds = [
  'Meaning and key terms: ',
  'Worked examples and illustrations of ',
  'Importance and everyday applications of ',
  'Common misconceptions to correct about ',
  'Summary of the main ideas on ',
  'Review questions to check understanding of ',
];

/// "10.4 Atoms — 10.4.1 Atomic Structure" -> "Atomic Structure".
String _plainTopic(String label) {
  final last = label.split(' — ').last.trim();
  final plain = last.replaceFirst(RegExp(r'^\d+(\.\d+)*\s+'), '').trim();
  return plain.isEmpty ? last : plain;
}

/// The subject matter of an outcome: "Describe an atom and its structure" ->
/// "an atom and its structure" (syllabus outcomes lead with their action word).
String _subjectMatter(String outcome) {
  final words = outcome.trim().split(RegExp(r'\s+'));
  if (words.length < 3) return outcome.trim();
  final rest = words.skip(1).join(' ');
  // "Distinguish between X and Y" -> "the difference between X and Y".
  return words[1].toLowerCase() == 'between' ? 'the difference $rest' : rest;
}

/// Pads [points] up to [min] (default [kMinimumContentPoints]). When real
/// points already reach [min] nothing is added. Otherwise the gap is filled
/// with teaching-move prompts about the syllabus [outcomes] (or, with none,
/// about [topicLabel]) — e.g. "Worked examples and illustrations of an atom
/// and its structure" — so the list is never thin, yet never claims content
/// the app does not have.
List<String> ensureMinimumPoints(
  List<String> points, {
  required List<String> outcomes,
  required String topicLabel,
  int min = kMinimumContentPoints,
}) {
  final result = _unique(points).toList();
  if (result.length >= min) return result;
  final matters = outcomes.isEmpty ? [_plainTopic(topicLabel)] : [for (final o in outcomes) _subjectMatter(o)];
  for (final scaffold in _scaffolds) {
    for (final matter in matters) {
      if (result.length >= min) return result;
      final candidate = '$scaffold$matter';
      final key = candidate.toLowerCase();
      if (!result.any((r) => r.toLowerCase() == key)) result.add(candidate);
    }
  }
  return result;
}

/// [ensureMinimumPoints] for a Content cell's existing text (one point per
/// line, any bullet markers) — used on AI/notes results that came back short.
String ensureContentText(String content, {required List<String> outcomes, required String topicLabel}) {
  final existing = [
    for (final line in content.split('\n'))
      if (line.trim().isNotEmpty) line.replaceFirst(_bulletMarker, '').trim(),
  ];
  return bulletLines(ensureMinimumPoints(topUpPoints(existing, outcomes), outcomes: outcomes, topicLabel: topicLabel));
}
