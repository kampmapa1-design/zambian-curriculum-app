/// Keeps Grade 10-12 (OBC 2013) documents clean of junior-secondary and
/// exam-paper noise (2026-09-27, per explicit request: "never mention Form 1,
/// 2, 3, 4 or Form five content when preparing work for Grade 10, 11 and 12
/// ... use the information silently ... and never put question marks on the
/// document").
///
/// The bundled Subject Content Database holds real material written for
/// other levels (e.g. CBC Form 1 teaching modules) and ECZ past papers whose
/// text is full of questions. That subject knowledge is still valid teaching
/// content — it is used, but silently: any sentence that names a Form level,
/// asks a question, carries exam-paper scaffolding or is CBC module
/// boilerplate is dropped, and the rest is kept as plain statements.
bool isSeniorSecondaryCurriculum(String curriculumCode) => curriculumCode == 'OBC_2013';

final _formMention = RegExp(r'\bforms?\s*(?:[1-5]|one|two|three|four|five)\b', caseSensitive: false);
final _shortFormMention = RegExp(r'\bF[1-5]\b');

/// Exam-paper scaffolding and CBC-module boilerplate — never part of a
/// teaching point.
final _noise = RegExp(
  r'\bquestion\s+\d+|\bpaper\s+\d|\bsection\s+[a-d]\b|\[\s*\d+\s*(?:marks?)?\s*\]|\(\s*\d+\s*marks?\s*\)|'
  r'^\s*\(\s*(?:[a-z]|[ivx]+)\s*\)|teaching module|competence[- ]based|competency[- ]based|\bcbc\b|'
  r'21st[- ]century|how to use (?:this|the) module|\bterm\s+[1-3]\b|\bmodel answer\b',
  caseSensitive: false,
);

final _sentenceBreak = RegExp(r'(?<=[.!?])\s+');

bool mentionsJuniorForm(String text) => _formMention.hasMatch(text) || _shortFormMention.hasMatch(text);

int _words(String s) => s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

bool _keepSourceSentence(String sentence) =>
    !mentionsJuniorForm(sentence) &&
    !sentence.contains('?') &&
    !sentence.contains('�') &&
    !_noise.hasMatch(sentence) &&
    _words(sentence) >= 4;

/// Cleans real SOURCE material (subject-content / pamphlet text) before it is
/// used as grounding for a Grade 10-12 document. Paragraph breaks are kept;
/// paragraphs left with nothing are dropped. Returns an empty string when
/// nothing usable remains.
String cleanSourceText(String text) {
  final paragraphs = <String>[];
  for (var paragraph in text.split(RegExp(r'\n\s*\n'))) {
    final marker = paragraph.toLowerCase().indexOf('model answer:');
    // An ECZ item is "Question ... Model answer: ..." — the answer is real
    // subject content, the question is not.
    if (marker != -1) paragraph = paragraph.substring(marker + 'model answer:'.length);
    final sentences = paragraph
        .replaceAll(RegExp(r'\s*\n\s*'), ' ')
        .split(_sentenceBreak)
        .map((s) => s.trim())
        .where(_keepSourceSentence);
    if (sentences.isNotEmpty) paragraphs.add(sentences.join(' '));
  }
  return paragraphs.join('\n\n');
}

/// Placeholder question marks ("?", "??", "(?)", "[?]") — uncertainty
/// markers, never real content.
final _placeholderQuestion = RegExp(r'\(\s*\?+\s*\)|\[\s*\?+\s*\]|\?{2,}|(?<=\s)\?+(?=\s|$)|^\?+\s');

final _mentionPhrase = RegExp(
  r'\(?\s*\b(?:forms?\s*(?:[1-5]|one|two|three|four|five)(?:\s*(?:-|to|and|&)\s*(?:[1-5]|one|two|three|four|five))?|F[1-5])\b\s*\)?',
  caseSensitive: false,
);

/// Cleans GENERATED text (AI output, an embedded lesson plan's fields) for a
/// Grade 10-12 document, line by line so bullets survive: sentences naming a
/// Form level are dropped (if that would empty a line, just the mention is
/// removed) and placeholder question marks are stripped. Genuine questions a
/// teacher would ask learners are left alone.
String cleanGeneratedText(String text) {
  final lines = <String>[];
  for (final line in text.split('\n')) {
    var cleaned = line;
    if (mentionsJuniorForm(line)) {
      final kept = line.split(_sentenceBreak).where((s) => !mentionsJuniorForm(s)).join(' ').trim();
      // Keep a leading bullet exactly as written ("•  " has two spaces).
      final prefix = RegExp(r'^\s*(?:[•\-*]\s+)?').firstMatch(line)!.group(0)!;
      cleaned = kept.isNotEmpty ? '${kept == line.trim() ? '' : prefix}$kept' : line.replaceAll(_mentionPhrase, ' ');
    }
    cleaned = _tidy(cleaned.replaceAll(_placeholderQuestion, ''));
    lines.add(cleaned);
  }
  return lines.join('\n');
}

/// Collapses runs of spaces inside a line, leaving any leading bullet's own
/// spacing alone, and trims the end.
String _tidy(String line) {
  final prefix = RegExp(r'^\s*(?:[•\-*]\s+)?').firstMatch(line)!.group(0)!;
  final rest = line.substring(prefix.length).replaceAll(RegExp(r'[ \t]{2,}'), ' ').trimRight();
  return '$prefix$rest';
}
