import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/required_core_topic_resolver.dart';

/// Permanent regression test for two real, reported bugs (2026-09-13) in
/// "Required Core Topics":
/// 1. A short scheme (few entries left this term) could be pushed off
///    entirely, leaving ONLY the newly-added required topics — this
///    covers requiredCoreTopicPushCount, the fix for that.
/// 2. Newly-added topics rendered with a blank "Specific Competence /
///    Outcomes" column — fixed by always synthesizing at least one real
///    competency/objective directly in [RequiredCoreTopicResolver.resolve]
///    itself, never leaving them empty pending a separate AI enrichment
///    pass that could silently not finish. That fix isn't covered here —
///    resolve() needs the syllabus/Firebase/file-system dependencies
///    mocked; this file locks in the push-count half, which is pure and
///    trivially unit-testable on its own.
void main() {
  group('requiredCoreTopicPushCount', () {
    test('normal case: pushes off exactly the requested count', () {
      expect(requiredCoreTopicPushCount(3, 13), 3);
      expect(requiredCoreTopicPushCount(1, 5), 1);
    });

    test('never empties the scheme — leaves at least one existing entry', () {
      // The real reported bug: 3 requested topics against a term that
      // only has 3 (or fewer) entries left used to push off ALL of them.
      expect(requiredCoreTopicPushCount(3, 3), 2);
      expect(requiredCoreTopicPushCount(3, 2), 1);
      expect(requiredCoreTopicPushCount(3, 1), 0);
    });

    test('an already-empty scheme pushes off nothing (nothing to push)', () {
      expect(requiredCoreTopicPushCount(3, 0), 0);
    });

    test('zero requested topics pushes off nothing', () {
      expect(requiredCoreTopicPushCount(0, 10), 0);
    });
  });
}
