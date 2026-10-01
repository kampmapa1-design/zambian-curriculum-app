import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/embedded_content_index_service.dart';
import 'package:zambian_curriculum_app/services/match_confidence_scorer.dart';

import 'support/sqlite_test_setup.dart';

/// Exercises the real SQLite storage layer (see sqlite_test_setup.dart for
/// why this needs the FFI-backed sqflite factory under `flutter test`)
/// against the real bundled assets/lesson_plans content — the same
/// real-content approach as embedded_content_search_real_content_test.dart,
/// but through the actual index/search path a caller would use, including
/// whichever of FTS5-or-fallback this machine's SQLite build actually
/// supports.
void main() {
  setUp(() async => setUpTestDatabase());

  test('ensureIndexed populates the segments table from the real bundled content', () async {
    final service = EmbeddedContentIndexService();
    await service.ensureIndexed();
    final matches = await service.search(query: 'reasons for learning history', curriculumCode: 'CBC_2023', subjectCode: 'HIST', gradeLevel: 1);
    expect(matches, isNotEmpty);
    expect(matches.first.tier, MatchConfidenceTier.strong);
  });

  test('search is scoped: the same query against a subject/grade with no such content returns nothing', () async {
    final service = EmbeddedContentIndexService();
    await service.ensureIndexed();
    final matches = await service.search(query: 'reasons for learning history', curriculumCode: 'CBC_2023', subjectCode: 'HIST', gradeLevel: 99);
    expect(matches, isEmpty);
  });

  test('ensureIndexed is idempotent — calling it again without new content does not duplicate rows', () async {
    final service = EmbeddedContentIndexService();
    await service.ensureIndexed();
    final first = await service.search(query: 'reasons for learning history', curriculumCode: 'CBC_2023', subjectCode: 'HIST', gradeLevel: 1);
    await service.ensureIndexed();
    final second = await service.search(query: 'reasons for learning history', curriculumCode: 'CBC_2023', subjectCode: 'HIST', gradeLevel: 1);
    expect(second.length, first.length);
  });

  group('fineTuneCandidatesForTopic (Stage 6/9)', () {
    test('a real broad History Form 1 topic surfaces its own real sub-topic as a Strong candidate', () async {
      final service = EmbeddedContentIndexService();
      await service.ensureIndexed();
      final candidates = await service.fineTuneCandidatesForTopic(
        curriculumCode: 'CBC_2023',
        subjectCode: 'HIST',
        gradeLevel: 1,
        topicName: '1.1 INTRODUCTION TO HISTORY',
        existingEntryNames: const {},
      );
      expect(candidates, isNotEmpty);
      final match = candidates.where((c) => c.subtopicName.toLowerCase().contains('reasons for learning history'));
      expect(match, isNotEmpty);
      expect(match.first.tier, MatchConfidenceTier.strong);
    });

    test('a sub-topic already represented in the scheme is excluded from the candidate list', () async {
      final service = EmbeddedContentIndexService();
      await service.ensureIndexed();
      final candidates = await service.fineTuneCandidatesForTopic(
        curriculumCode: 'CBC_2023',
        subjectCode: 'HIST',
        gradeLevel: 1,
        topicName: '1.1 INTRODUCTION TO HISTORY',
        existingEntryNames: {'1.1.1 reasons for learning history'},
      );
      expect(candidates.where((c) => c.subtopicName.toLowerCase().contains('reasons for learning history')), isEmpty);
    });

    test('a topic with no embedded content at all returns no candidates, not an error', () async {
      final service = EmbeddedContentIndexService();
      await service.ensureIndexed();
      final candidates = await service.fineTuneCandidatesForTopic(
        curriculumCode: 'CBC_2023',
        subjectCode: 'HIST',
        gradeLevel: 1,
        topicName: 'Not A Real Bundled Topic Name',
        existingEntryNames: const {},
      );
      expect(candidates, isEmpty);
    });
  });
}
