import '../models/embedded_content_segment.dart';
import 'embedded_content_index_builder.dart';
import 'match_confidence_scorer.dart';

/// One real embedded sub-topic found bundled inside a broader scheme
/// topic, not yet represented as its own scheme entry — Embedded Content
/// Search Stage 6 ("Fine Tune").
class FineTuneCandidate {
  final String groupKey;
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final String topicName;
  final String subtopicName;
  final MatchConfidenceTier tier;
  final int bodyWordCount;
  final String excerpt;

  const FineTuneCandidate({
    required this.groupKey,
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.topicName,
    required this.subtopicName,
    required this.tier,
    required this.bodyWordCount,
    required this.excerpt,
  });
}

/// Finds real, structurally distinct sub-topics bundled inside a broader
/// topic's embedded lesson plans — the "we found these more specific
/// topics that may be bundled inside [broad topic]" list behind Fine Tune.
/// Pure and offline: works entirely from segments the caller has already
/// scoped to one curriculum/subject/grade/topic (see
/// EmbeddedContentIndexService.segmentsForTopic), so it's directly
/// unit-testable without a database.
///
/// A candidate is "structural" here in a different sense than
/// [MatchConfidenceScorer]'s free-text matching: there's no search query to
/// score against, since the sub-topic's own real name IS the signal. Tier
/// instead reflects how much real body content actually backs that
/// sub-topic — a name with substantial real lesson content behind it is a
/// confident candidate for its own scheme entry; a bare heading with
/// almost nothing under it is not (excluded outright, not even shown as
/// Weak — Stage 7 only ever offers Strong or Moderate).
class FineTuneCandidateFinder {
  const FineTuneCandidateFinder();

  static const kStrongBodyWords = 150;
  static const kModerateBodyWords = 40;
  static const kExcerptWords = 80;

  List<FineTuneCandidate> find({
    required String topicName,
    required List<EmbeddedContentSegment> segmentsForTopic,
    required Set<String> existingEntryNames,
  }) {
    final byGroup = <String, List<EmbeddedContentSegment>>{};
    for (final s in segmentsForTopic) {
      final subtopic = s.subtopicName;
      if (subtopic == null || subtopic.trim().isEmpty) continue; // the topic's own row, not a candidate sub-topic
      byGroup.putIfAbsent(s.groupKey, () => []).add(s);
    }

    final candidates = <FineTuneCandidate>[];
    for (final group in byGroup.values) {
      final subtopicName = group.first.subtopicName!;
      if (existingEntryNames.contains(normalizeHeadingKey(subtopicName))) continue;

      final bodySegments = group.where((s) => s.kind == EmbeddedContentSegmentKind.body).toList()
        ..sort((a, b) => a.segmentOrder.compareTo(b.segmentOrder));
      final bodyWords = <String>[];
      for (final s in bodySegments) {
        bodyWords.addAll(s.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty));
      }

      final tier = bodyWords.length >= kStrongBodyWords
          ? MatchConfidenceTier.strong
          : (bodyWords.length >= kModerateBodyWords ? MatchConfidenceTier.moderate : MatchConfidenceTier.weak);
      if (tier == MatchConfidenceTier.weak) continue;

      final excerptWords = bodyWords.take(kExcerptWords).toList();
      final excerpt = excerptWords.length < bodyWords.length ? '${excerptWords.join(' ')}...' : excerptWords.join(' ');

      candidates.add(FineTuneCandidate(
        groupKey: group.first.groupKey,
        curriculumCode: group.first.curriculumCode,
        subjectCode: group.first.subjectCode,
        gradeLevel: group.first.gradeLevel,
        topicName: topicName,
        subtopicName: subtopicName,
        tier: tier,
        bodyWordCount: bodyWords.length,
        excerpt: excerpt,
      ));
    }

    candidates.sort((a, b) {
      if (a.tier != b.tier) return a.tier == MatchConfidenceTier.strong ? -1 : 1;
      return b.bodyWordCount.compareTo(a.bodyWordCount);
    });
    return candidates;
  }
}
