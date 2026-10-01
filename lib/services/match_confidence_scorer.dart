import '../models/embedded_content_segment.dart';
import 'text_excerpt_matching.dart' show keywordsOf;

/// How confidently a candidate embedded-content document (see
/// [EmbeddedContentSegment.groupKey]) actually covers a search phrase —
/// Embedded Content Search Stage 2 (2026-09-22).
enum MatchConfidenceTier { strong, moderate, weak }

/// One scored candidate — the group it came from, its tier, and the
/// specific extracted passage (never the whole document) that justifies it.
class ContentMatch {
  final String groupKey;
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final String topicName;
  final String? subtopicName;
  final MatchConfidenceTier tier;
  final double score;
  final String excerpt;

  const ContentMatch({
    required this.groupKey,
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.topicName,
    this.subtopicName,
    required this.tier,
    required this.score,
    required this.excerpt,
  });

  /// The real heading this match is "found within" — the sub-topic when
  /// there is one (the specific, narrower real heading), else the topic.
  String get sourceTitle => (subtopicName != null && subtopicName!.trim().isNotEmpty) ? subtopicName! : topicName;
}

/// Scores how well a search phrase matches embedded content, combining four
/// signals (heading/subheading match weighted highest, per explicit
/// request): (1) does the phrase match the document's own heading/
/// sub-heading, (2) how densely the phrase's words are mentioned within a
/// realistic reading window, (3) how long a genuinely contiguous relevant
/// span is once found, (4) is the exact phrase (or a real variant of it)
/// actually present as whole words, not just fragments. Entirely pure/
/// offline — no dependency on how the segments were stored, so this is
/// directly unit-testable against hand-built segment lists, and separately
/// against real embedded content loaded from the bundled assets.
class MatchConfidenceScorer {
  const MatchConfidenceScorer();

  static const kStrongThreshold = 0.6;
  static const kModerateThreshold = 0.3;

  static const kHeadingWeight = 0.5;
  static const kDensityWeight = 0.2;
  static const kSpanWeight = 0.15;
  static const kPhraseWeight = 0.15;

  static const kWindowWords = 175;
  static const kWindowStepWords = 25;
  static const kDensityForFullCredit = 0.04;
  static const kMaxSpanWordsForFullCredit = 60;
  static const kExcerptWords = 120;

  /// Every non-null match across the groups present in [segments] (already
  /// scoped by the caller — e.g. to one curriculum/subject/grade), highest
  /// score first.
  List<ContentMatch> scoreAll({required String query, required List<EmbeddedContentSegment> segments}) {
    final byGroup = <String, List<EmbeddedContentSegment>>{};
    for (final s in segments) {
      byGroup.putIfAbsent(s.groupKey, () => []).add(s);
    }
    final matches = <ContentMatch>[];
    for (final group in byGroup.values) {
      final match = score(query: query, groupSegments: group);
      if (match != null) matches.add(match);
    }
    matches.sort((a, b) => b.score.compareTo(a.score));
    return matches;
  }

  /// Scores one candidate document (every segment sharing the same
  /// [EmbeddedContentSegment.groupKey]) against [query]. Null when nothing
  /// in the group shares any real wording with the query at all.
  ContentMatch? score({required String query, required List<EmbeddedContentSegment> groupSegments}) {
    if (groupSegments.isEmpty) return null;
    final keywords = keywordsOf(query);
    final phrase = query.toLowerCase().trim();
    if (keywords.isEmpty && phrase.isEmpty) return null;

    final headingSegments = groupSegments.where((s) => s.kind == EmbeddedContentSegmentKind.heading);
    final bodySegments = groupSegments.where((s) => s.kind == EmbeddedContentSegmentKind.body).toList()
      ..sort((a, b) => a.segmentOrder.compareTo(b.segmentOrder));

    final headingScore = _headingScore(headingSegments.map((s) => s.text), keywords, phrase);

    final bodyWords = <String>[];
    for (final s in bodySegments) {
      bodyWords.addAll(s.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty));
    }
    final window = _bestWindow(bodyWords, keywords);
    final densityScore = window == null ? 0.0 : (window.density / kDensityForFullCredit).clamp(0.0, 1.0);
    final spanScore = window == null ? 0.0 : (window.spanWords / kMaxSpanWordsForFullCredit).clamp(0.0, 1.0);

    final wholeTextForPhraseCheck = ([...headingSegments.map((s) => s.text), bodyWords.join(' ')]).join(' ');
    final phraseScore = _wholePhraseOrVariantPresent(wholeTextForPhraseCheck, phrase, keywords) ? 1.0 : 0.0;

    final total = kHeadingWeight * headingScore +
        kDensityWeight * densityScore +
        kSpanWeight * spanScore +
        kPhraseWeight * phraseScore;

    if (total <= 0) return null;

    final tier = total >= kStrongThreshold
        ? MatchConfidenceTier.strong
        : (total >= kModerateThreshold ? MatchConfidenceTier.moderate : MatchConfidenceTier.weak);

    final excerpt = _excerptFor(window, bodyWords);
    final first = groupSegments.first;
    return ContentMatch(
      groupKey: first.groupKey,
      curriculumCode: first.curriculumCode,
      subjectCode: first.subjectCode,
      gradeLevel: first.gradeLevel,
      topicName: first.topicName,
      subtopicName: first.subtopicName,
      tier: tier,
      score: total,
      excerpt: excerpt,
    );
  }

  double _headingScore(Iterable<String> headings, Set<String> keywords, String phrase) {
    var best = 0.0;
    for (final heading in headings) {
      final lower = heading.toLowerCase();
      double s;
      if (phrase.isNotEmpty && lower.contains(phrase)) {
        s = 1.0;
      } else if (keywords.isNotEmpty) {
        final headingWords = keywordsOf(heading);
        final hits = keywords.where((k) => headingWords.any((h) => h.contains(k) || k.contains(h))).length;
        final fraction = hits / keywords.length;
        s = fraction >= 1.0 ? 0.7 : 0.3 * fraction;
      } else {
        s = 0.0;
      }
      if (s > best) best = s;
    }
    return best;
  }

  bool _isMention(String word, Set<String> keywords) {
    final lower = word.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (lower.length <= 3) return false;
    return keywords.any((k) => lower.contains(k) || k.contains(lower));
  }

  _Window? _bestWindow(List<String> bodyWords, Set<String> keywords) {
    if (bodyWords.isEmpty || keywords.isEmpty) return null;
    final windowSize = bodyWords.length < kWindowWords ? bodyWords.length : kWindowWords;
    _Window? best;
    for (var start = 0; start < bodyWords.length; start += kWindowStepWords) {
      final end = (start + windowSize < bodyWords.length) ? start + windowSize : bodyWords.length;
      if (end <= start) continue;
      int? firstHit;
      int? lastHit;
      var mentions = 0;
      for (var i = start; i < end; i++) {
        if (_isMention(bodyWords[i], keywords)) {
          mentions++;
          firstHit ??= i;
          lastHit = i;
        }
      }
      if (mentions == 0) continue;
      final density = mentions / (end - start);
      final spanWords = mentions >= 2 ? (lastHit! - firstHit! + 1) : 0;
      if (best == null || density > best.density) {
        best = _Window(start: start, end: end, density: density, spanWords: spanWords, mentions: mentions);
      }
      if (end >= bodyWords.length) break;
    }
    return best;
  }

  bool _wholePhraseOrVariantPresent(String text, String phrase, Set<String> keywords) {
    final variants = <String>{if (phrase.isNotEmpty) phrase, ...keywords};
    for (final v in variants) {
      final escaped = RegExp.escape(v);
      if (RegExp(r'\b' + escaped + r'\b', caseSensitive: false).hasMatch(text)) return true;
    }
    return false;
  }

  String _excerptFor(_Window? window, List<String> bodyWords) {
    if (bodyWords.isEmpty) return '';
    if (window == null) {
      final words = bodyWords.take(kExcerptWords).toList();
      return words.length < bodyWords.length ? '${words.join(' ')}...' : words.join(' ');
    }
    final words = bodyWords.sublist(window.start, window.end).take(kExcerptWords).toList();
    final truncated = words.length < (window.end - window.start);
    return truncated ? '${words.join(' ')}...' : words.join(' ');
  }
}

class _Window {
  final int start;
  final int end;
  final double density;
  final int spanWords;
  final int mentions;
  const _Window({required this.start, required this.end, required this.density, required this.spanWords, required this.mentions});
}
