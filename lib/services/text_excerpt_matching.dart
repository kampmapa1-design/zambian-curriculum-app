/// Words worth matching on — anything longer than 3 characters, same
/// threshold used throughout this app's offline keyword-overlap matching
/// (see e.g. TopicSearchService's own word scoring).
Set<String> keywordsOf(String text) => text
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((w) => w.length > 3)
    .toSet();

/// Caps [text] at [maxWords] words, appending "..." when it was longer —
/// keeps a matched excerpt readable rather than dumping a whole document.
String capExcerptWords(String text, int maxWords) {
  final words = text.trim().split(RegExp(r'\s+'));
  if (words.length <= maxWords) return text.trim();
  return '${words.take(maxWords).join(' ')}...';
}

/// The single best-matching excerpt within [text] for [keywords] — scores
/// each paragraph by how many distinct keywords it contains, and returns
/// the highest-scoring one (folding in a short following paragraph as
/// likely context/continuation), capped at [maxExcerptWords]. Shared by
/// SubjectContentRepository.findRelevantExcerpt (one excerpt, scoped to a
/// specific topic/subject) and .searchContent (every matching item across
/// the whole on-device Subject Content Database) so the same real scoring
/// rule isn't duplicated between them. Null when nothing in [text] shares
/// any of [keywords] at all.
({String excerpt, int score})? bestExcerptFor(String text, Set<String> keywords, {int maxExcerptWords = 350}) {
  final paragraphs = text.split(RegExp(r'\n\s*\n')).where((p) => p.trim().length > 40).toList();
  String? bestExcerpt;
  var bestScore = 0;
  for (var i = 0; i < paragraphs.length; i++) {
    final paragraph = paragraphs[i].trim();
    final paragraphWords = keywordsOf(paragraph);
    final score = keywords.where(paragraphWords.contains).length;
    if (score > bestScore) {
      bestScore = score;
      final extended = (i + 1 < paragraphs.length && paragraphs[i + 1].trim().length < 300)
          ? '$paragraph\n\n${paragraphs[i + 1].trim()}'
          : paragraph;
      bestExcerpt = capExcerptWords(extended, maxExcerptWords);
    }
  }
  return bestScore > 0 && bestExcerpt != null ? (excerpt: bestExcerpt, score: bestScore) : null;
}
