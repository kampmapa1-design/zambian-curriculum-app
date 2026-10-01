import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';
import 'package:zambian_curriculum_app/services/embedded_content_index_service.dart';
import 'package:zambian_curriculum_app/services/embedded_lesson_plan_repository.dart';
import 'package:zambian_curriculum_app/services/fine_tune_topic_builder.dart';
import 'package:zambian_curriculum_app/services/match_confidence_scorer.dart';
import 'package:zambian_curriculum_app/services/required_core_topic_resolver.dart' show requiredCoreTopicPushCount;

import 'support/sqlite_test_setup.dart';

/// Embedded Content Search Stage 9's own requirement: an end-to-end
/// regression test using a known real broad topic already on a scheme
/// (here, the real bundled "1.1 INTRODUCTION TO HISTORY", History Form 1 —
/// see assets/lesson_plans/history_form1.json) and known real embedded
/// content, asserting Fine Tune surfaces its real, more specific
/// "1.1.1 Reasons for Learning History" sub-topic as a Strong-tier
/// candidate, and that confirming it inserts correctly through the SAME
/// insertion mechanics scheme_of_work_document_screen.dart's
/// _insertAtFrontPushingOffEnd uses (requiredCoreTopicPushCount, plus a
/// front-insert/end-push list rebuild) without breaking the scheme's
/// topic count or its floor protection.
///
/// Doesn't drive scheme_of_work_document_screen.dart's own widget tree —
/// that screen has no pre-existing test harness at all (several of its
/// own dependencies construct real Firebase objects eagerly), so building
/// one from scratch here would be disproportionate to what this test
/// needs to prove: the real data pipeline behind the button, not the
/// button itself. Disclosed, not silently skipped.
void main() {
  setUp(() async => setUpTestDatabase());

  SchemeOfWorkEntry entryFor(String topicName, {String? subtopicName, int id = 1}) => SchemeOfWorkEntry(
        weekNumber: 1,
        topic: Topic(id: id, sequenceNumber: 1, name: topicName),
        objectives: const [],
        competencies: const [],
      );

  test('Fine Tune surfaces the real sub-topic as Strong, and inserting it preserves topic count with floor protection', () async {
    final indexService = EmbeddedContentIndexService();
    await indexService.ensureIndexed();

    // A real, currently-generated scheme for this term: just the broad
    // topic itself, nothing yet for its real "Reasons for Learning
    // History" sub-topic — plus a couple of other real, unrelated topics,
    // so the push-count/floor-protection behaviour is meaningfully
    // exercised (not a trivial 1-entry scheme).
    var currentEntries = <SchemeOfWorkEntry>[
      entryFor('1.1 INTRODUCTION TO HISTORY', id: 1),
      entryFor('1.2 Measuring Time', id: 2),
      entryFor('1.3 Origins of Man', id: 3),
    ];
    final originalCount = currentEntries.length;

    final existingNames = {
      for (final e in currentEntries) e.topic.name.toLowerCase().trim(),
    };

    final candidates = await indexService.fineTuneCandidatesForTopic(
      curriculumCode: 'CBC_2023',
      subjectCode: 'HIST',
      gradeLevel: 1,
      topicName: '1.1 INTRODUCTION TO HISTORY',
      existingEntryNames: existingNames,
    );

    final strongHit = candidates.where(
      (c) => c.tier == MatchConfidenceTier.strong && c.subtopicName.toLowerCase().contains('reasons for learning history'),
    );
    expect(strongHit, isNotEmpty, reason: 'the real sub-topic should surface as a Strong candidate');
    final chosen = strongHit.first;

    // Confirming: fetch the REAL underlying lesson plans and build a real
    // Topic from them — exactly what the screen's _openFineTune does.
    final plans = await EmbeddedLessonPlanRepository().find(
      curriculumCode: chosen.curriculumCode,
      subjectCode: chosen.subjectCode,
      gradeLevel: chosen.gradeLevel,
      topicName: chosen.topicName,
      subtopicName: chosen.subtopicName,
    );
    expect(plans, isNotEmpty);

    var syntheticId = -800000;
    final newTopic = const FineTuneTopicBuilder().build(
      topicName: chosen.topicName,
      subtopicName: chosen.subtopicName,
      plans: plans,
      nextSyntheticId: () => syntheticId--,
    );
    expect(newTopic.id, lessThan(0));
    expect(newTopic.competencies.length + newTopic.objectives.length, greaterThan(0));

    final newEntry = SchemeOfWorkEntry(weekNumber: 0, topic: newTopic, objectives: newTopic.objectives, competencies: newTopic.competencies);

    // The exact insertion mechanics _insertAtFrontPushingOffEnd uses.
    final pushCount = requiredCoreTopicPushCount(1, currentEntries.length);
    final pushedOff = currentEntries.sublist(currentEntries.length - pushCount);
    final kept = currentEntries.sublist(0, currentEntries.length - pushCount);
    currentEntries = [newEntry, ...kept];

    expect(currentEntries, hasLength(originalCount), reason: 'topic count preserved — one added, one pushed off, none lost');
    expect(currentEntries.first.topic.name.toLowerCase(), contains('reasons for learning history'));
    expect(pushedOff, hasLength(1));
    expect(currentEntries, isNot(contains(pushedOff.single)), reason: "the pushed-off entry is really gone from this term's list");
  });

  test('a topic that already has every real sub-topic represented in the scheme surfaces no Fine Tune candidates at all', () async {
    final indexService = EmbeddedContentIndexService();
    await indexService.ensureIndexed();

    final candidates = await indexService.fineTuneCandidatesForTopic(
      curriculumCode: 'CBC_2023',
      subjectCode: 'HIST',
      gradeLevel: 1,
      topicName: '1.1 INTRODUCTION TO HISTORY',
      existingEntryNames: {'1.1.1 reasons for learning history'},
    );
    expect(candidates.where((c) => c.subtopicName.toLowerCase().contains('reasons for learning history')), isEmpty);
  });
}
