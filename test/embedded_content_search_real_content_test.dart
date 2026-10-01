import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/embedded_content_segment.dart';
import 'package:zambian_curriculum_app/services/embedded_content_index_builder.dart';
import 'package:zambian_curriculum_app/services/embedded_lesson_plan_repository.dart';
import 'package:zambian_curriculum_app/services/match_confidence_scorer.dart';

/// Embedded Content Search Stage 2's own requirement: "Write a test suite
/// using known real embedded plans and known keywords with manually
/// verified expected tiers." Uses the actual bundled
/// assets/lesson_plans/*.json content (real, sanitized teacher-authored
/// lesson plans — see each file's own `_source` field), not fabricated
/// text, so this is a genuine check against what's really indexed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<EmbeddedContentSegment> segments;

  setUpAll(() async {
    final sets = await EmbeddedLessonPlanRepository().allSets();
    expect(sets, isNotEmpty, reason: 'expected real bundled lesson plan sets under assets/lesson_plans/');
    segments = buildEmbeddedContentSegments(sets);
  });

  test('a real sub-topic heading (History Form 1, "Reasons for Learning History") scores Strong for its own real wording', () {
    const scorer = MatchConfidenceScorer();
    final scoped = segments
        .where((s) => s.curriculumCode == 'CBC_2023' && s.subjectCode == 'HIST' && s.gradeLevel == 1)
        .toList();
    expect(scoped, isNotEmpty, reason: 'expected the real history_form1.json content to be indexed');

    final matches = scorer.scoreAll(query: 'reasons for learning history', segments: scoped);
    expect(matches, isNotEmpty);
    final top = matches.first;
    expect(top.tier, MatchConfidenceTier.strong);
    expect(top.sourceTitle.toLowerCase(), contains('reasons for learning history'));
  });

  test('a query sharing no real wording with anything indexed returns no Strong/Moderate matches', () {
    const scorer = MatchConfidenceScorer();
    final matches = scorer.scoreAll(query: 'xylophone quantum blockchain zzznonexistent', segments: segments);
    expect(matches.where((m) => m.tier != MatchConfidenceTier.weak), isEmpty);
  });
}
