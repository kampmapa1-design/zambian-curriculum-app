import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/embedded_content_segment.dart';
import 'package:zambian_curriculum_app/services/fine_tune_candidate_finder.dart';
import 'package:zambian_curriculum_app/services/match_confidence_scorer.dart';

EmbeddedContentSegment _body(String subtopic, String text, {int order = 1, String topic = 'Broad Topic'}) =>
    EmbeddedContentSegment(
      groupKey: 'Broad Topic|$subtopic',
      curriculumCode: 'CBC_2023',
      subjectCode: 'HIST',
      gradeLevel: 10,
      topicName: topic,
      subtopicName: subtopic,
      kind: EmbeddedContentSegmentKind.body,
      segmentOrder: order,
      text: text,
    );

EmbeddedContentSegment _heading(String subtopic, {String topic = 'Broad Topic'}) => EmbeddedContentSegment(
      groupKey: 'Broad Topic|$subtopic',
      curriculumCode: 'CBC_2023',
      subjectCode: 'HIST',
      gradeLevel: 10,
      topicName: topic,
      subtopicName: subtopic,
      kind: EmbeddedContentSegmentKind.heading,
      segmentOrder: 0,
      text: subtopic,
    );

String _words(int n) => List.filled(n, 'word').join(' ');

void main() {
  const finder = FineTuneCandidateFinder();

  test('a sub-topic with substantial real body content is a Strong candidate', () {
    final segments = [_heading('Sub A'), _body('Sub A', _words(200))];
    final candidates = finder.find(topicName: 'Broad Topic', segmentsForTopic: segments, existingEntryNames: const {});
    expect(candidates, hasLength(1));
    expect(candidates.single.tier, MatchConfidenceTier.strong);
    expect(candidates.single.subtopicName, 'Sub A');
  });

  test('a sub-topic with modest real body content is a Moderate candidate', () {
    final segments = [_heading('Sub B'), _body('Sub B', _words(60))];
    final candidates = finder.find(topicName: 'Broad Topic', segmentsForTopic: segments, existingEntryNames: const {});
    expect(candidates.single.tier, MatchConfidenceTier.moderate);
  });

  test('a sub-topic with only a bare heading and almost no body content is excluded entirely (not even Weak)', () {
    final segments = [_heading('Sub C'), _body('Sub C', _words(5))];
    final candidates = finder.find(topicName: 'Broad Topic', segmentsForTopic: segments, existingEntryNames: const {});
    expect(candidates, isEmpty);
  });

  test('a sub-topic already represented in the scheme is excluded, case/whitespace-insensitively', () {
    final segments = [_heading('  Sub D  '), _body('  Sub D  ', _words(200))];
    final candidates = finder.find(topicName: 'Broad Topic', segmentsForTopic: segments, existingEntryNames: {'sub d'});
    expect(candidates, isEmpty);
  });

  test('the topic\'s own row (no sub-topic) is never itself a candidate', () {
    final segments = [
      const EmbeddedContentSegment(
        groupKey: 'Broad Topic|',
        curriculumCode: 'CBC_2023',
        subjectCode: 'HIST',
        gradeLevel: 10,
        topicName: 'Broad Topic',
        kind: EmbeddedContentSegmentKind.heading,
        segmentOrder: 0,
        text: 'Broad Topic',
      ),
    ];
    final candidates = finder.find(topicName: 'Broad Topic', segmentsForTopic: segments, existingEntryNames: const {});
    expect(candidates, isEmpty);
  });

  test('Strong candidates sort ahead of Moderate ones, and within a tier, more content sorts first', () {
    final segments = [
      _heading('Small Strong'), _body('Small Strong', _words(150)),
      _heading('Big Strong'), _body('Big Strong', _words(400)),
      _heading('Moderate'), _body('Moderate', _words(50)),
    ];
    final candidates = finder.find(topicName: 'Broad Topic', segmentsForTopic: segments, existingEntryNames: const {});
    expect(candidates.map((c) => c.subtopicName), ['Big Strong', 'Small Strong', 'Moderate']);
  });

  test('an empty segment list returns no candidates', () {
    expect(finder.find(topicName: 'Broad Topic', segmentsForTopic: const [], existingEntryNames: const {}), isEmpty);
  });
}
