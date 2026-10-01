import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/embedded_content_segment.dart';
import 'package:zambian_curriculum_app/services/match_confidence_scorer.dart';

EmbeddedContentSegment _seg({
  required EmbeddedContentSegmentKind kind,
  required String text,
  int order = 0,
  String? subtopicName,
}) =>
    EmbeddedContentSegment(
      groupKey: 'g',
      curriculumCode: 'CBC_2023',
      subjectCode: 'HIST',
      gradeLevel: 10,
      topicName: 'The Mfecane',
      subtopicName: subtopicName,
      kind: kind,
      segmentOrder: order,
      text: text,
    );

void main() {
  const scorer = MatchConfidenceScorer();

  group('heading match (Stage 2, criterion 1 — highest weight)', () {
    test('the exact phrase as the sub-topic heading, with supporting body text, scores Strong', () {
      final segments = [
        _seg(kind: EmbeddedContentSegmentKind.heading, text: 'The Mfecane', subtopicName: 'Rise and Fall of a Great Leader'),
        _seg(kind: EmbeddedContentSegmentKind.heading, text: 'Rise and Fall of a Great Leader', subtopicName: 'Rise and Fall of a Great Leader'),
        _seg(
          kind: EmbeddedContentSegmentKind.body,
          order: 1,
          subtopicName: 'Rise and Fall of a Great Leader',
          text: List.generate(
            30,
            (i) => i.isEven
                ? 'The great leader united the clans and built a powerful nation through disciplined regiments.'
                : 'Neighbouring communities were affected by these campaigns across the region for many years.',
          ).join(' '),
        ),
      ];
      final match = scorer.score(query: 'rise and fall of a great leader', groupSegments: segments);
      expect(match, isNotNull);
      expect(match!.tier, MatchConfidenceTier.strong);
      expect(match.sourceTitle, 'Rise and Fall of a Great Leader');
    });

    test('a heading that shares none of the query words, with no body content, is not a match at all', () {
      final segments = [
        _seg(kind: EmbeddedContentSegmentKind.heading, text: 'Colonial Administration', subtopicName: 'Colonial Administration'),
      ];
      final match = scorer.score(query: 'measuring time with calendars', groupSegments: segments);
      expect(match, isNull);
    });
  });

  group('density and span (Stage 2, criteria 2 and 3)', () {
    test('dense, clustered mentions in the body (no heading support) score at least Moderate', () {
      final dense = List.generate(20, (_) => 'copper mining smelting furnaces copper ore extraction techniques').join(' ');
      final segments = [
        _seg(kind: EmbeddedContentSegmentKind.heading, text: 'Economic Activities', subtopicName: null),
        _seg(kind: EmbeddedContentSegmentKind.body, order: 1, text: dense),
      ];
      final match = scorer.score(query: 'copper mining', groupSegments: segments);
      expect(match, isNotNull);
      expect(match!.tier, isNot(MatchConfidenceTier.weak));
      expect(match.excerpt, contains('copper'));
    });

    test('a single stray mention buried in unrelated text (no heading support, low density) scores Weak', () {
      final sparse = [
        ...List.generate(90, (_) => 'unrelated filler word about something else entirely'),
        'a brief mention of irrigation farming appears once here',
        ...List.generate(90, (_) => 'more unrelated filler word about something else entirely'),
      ].join(' ');
      final segments = [
        _seg(kind: EmbeddedContentSegmentKind.heading, text: 'Economic Activities', subtopicName: null),
        _seg(kind: EmbeddedContentSegmentKind.body, order: 1, text: sparse),
      ];
      final match = scorer.score(query: 'irrigation farming', groupSegments: segments);
      expect(match, isNotNull);
      expect(match!.tier, MatchConfidenceTier.weak);
    });
  });

  group('variant handling (Stage 2, criterion 4)', () {
    test('a shorter variant of a multi-word query (e.g. just the distinctive name) still counts as a real mention', () {
      final segments = [
        _seg(kind: EmbeddedContentSegmentKind.heading, text: 'Nyirenda and the Great Migration', subtopicName: 'Nyirenda and the Great Migration'),
        _seg(
          kind: EmbeddedContentSegmentKind.body,
          order: 1,
          text: List.generate(10, (_) => 'Nyirenda led the people across the great river during the migration period.').join(' '),
        ),
      ];
      // Query names the phrase differently ("King Nyirenda") — the shared
      // distinctive keyword "Nyirenda" should still be recognised.
      final match = scorer.score(query: 'King Nyirenda', groupSegments: segments);
      expect(match, isNotNull);
      expect(match!.tier, isNot(MatchConfidenceTier.weak));
    });
  });

  group('scoreAll', () {
    test('groups segments by groupKey and returns highest-scoring first', () {
      const strongGroup = EmbeddedContentSegment(
        groupKey: 'strong',
        curriculumCode: 'CBC_2023',
        subjectCode: 'HIST',
        gradeLevel: 10,
        topicName: 'Topic A',
        subtopicName: 'Volcanic Activity in the Rift Valley',
        kind: EmbeddedContentSegmentKind.heading,
        segmentOrder: 0,
        text: 'Volcanic Activity in the Rift Valley',
      );
      const weakGroup = EmbeddedContentSegment(
        groupKey: 'weak',
        curriculumCode: 'CBC_2023',
        subjectCode: 'HIST',
        gradeLevel: 10,
        topicName: 'Topic B',
        kind: EmbeddedContentSegmentKind.body,
        segmentOrder: 0,
        text: 'a passing mention of volcanic rock formations among much unrelated filler text here and there',
      );
      final matches = scorer.scoreAll(query: 'volcanic activity', segments: [strongGroup, weakGroup]);
      expect(matches, isNotEmpty);
      expect(matches.first.groupKey, 'strong');
      expect(matches.first.score, greaterThanOrEqualTo(matches.last.score));
    });

    test('an empty segment list returns no matches', () {
      expect(scorer.scoreAll(query: 'anything', segments: const []), isEmpty);
    });
  });
}
