import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/match_confidence_scorer.dart';
import 'package:zambian_curriculum_app/services/required_core_topic_resolver.dart';

/// Embedded Content Search Stages 4/5 (2026-09-22) — the grounding-choice
/// decision RequiredCoreTopicResolver.resolve makes between the Subject
/// Content Database's generic keyword excerpt and a structurally-confirmed
/// embedded-content match, pulled out as chooseRequiredCoreTopicGrounding
/// so it's directly testable without resolve()'s real syllabus/Firebase/
/// file-system dependencies — the same reasoning as this file's sibling
/// test for requiredCoreTopicPushCount.
ContentMatch _match(MatchConfidenceTier tier) => ContentMatch(
      groupKey: 'g',
      curriculumCode: 'CBC_2023',
      subjectCode: 'HIST',
      gradeLevel: 1,
      topicName: 'Broad Topic',
      subtopicName: 'A Real Sub-Topic',
      tier: tier,
      score: 1,
      excerpt: 'A specific real passage about the sub-topic.',
    );

void main() {
  group('chooseRequiredCoreTopicGrounding', () {
    test('a Strong embedded match is preferred over the Subject Content Database excerpt', () {
      final grounding = chooseRequiredCoreTopicGrounding(
        embeddedMatch: _match(MatchConfidenceTier.strong),
        scdExcerpt: 'A generic keyword-matched excerpt.',
      );
      expect(grounding.usedEmbeddedContent, isTrue);
      expect(grounding.localContext, contains('A Real Sub-Topic'));
      expect(grounding.localContext, contains('A specific real passage'));
      expect(grounding.localContext, isNot(contains('generic keyword-matched excerpt')));
    });

    test('a Moderate embedded match still wins, and carries an explicit "limited source material" disclosure (Stage 5)', () {
      final grounding = chooseRequiredCoreTopicGrounding(
        embeddedMatch: _match(MatchConfidenceTier.moderate),
        scdExcerpt: null,
      );
      expect(grounding.usedEmbeddedContent, isTrue);
      expect(grounding.localContext, contains('LIMITED'));
    });

    test('a Strong match, by contrast, carries no "limited" disclosure', () {
      final grounding = chooseRequiredCoreTopicGrounding(embeddedMatch: _match(MatchConfidenceTier.strong), scdExcerpt: null);
      expect(grounding.localContext, isNot(contains('LIMITED')));
    });

    test('a Weak embedded match is never used as grounding — falls back to the Subject Content Database excerpt', () {
      final grounding = chooseRequiredCoreTopicGrounding(
        embeddedMatch: _match(MatchConfidenceTier.weak),
        scdExcerpt: 'A generic SCD excerpt.',
      );
      expect(grounding.usedEmbeddedContent, isFalse);
      expect(grounding.localContext, 'A generic SCD excerpt.');
    });

    test('no embedded match at all falls back to whatever the Subject Content Database found (possibly nothing)', () {
      expect(
        chooseRequiredCoreTopicGrounding(embeddedMatch: null, scdExcerpt: 'SCD excerpt.').localContext,
        'SCD excerpt.',
      );
      final none = chooseRequiredCoreTopicGrounding(embeddedMatch: null, scdExcerpt: null);
      expect(none.localContext, isNull);
      expect(none.usedEmbeddedContent, isFalse);
    });
  });
}
