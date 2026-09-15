import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zambian_curriculum_app/services/free_tier_entitlement_service.dart';

/// Home Assignment epic, Stage 3 — real regression coverage for
/// [FreeTierEntitlementService], which had NO automated test at all
/// despite being genuine monthly-quota tracking logic (the exact kind of
/// off-by-one/period-rollover bug that's easy to get wrong and easy to
/// miss by eye). [kFreeTierCapEnforced] is false right now (see that
/// flag's own doc comment), so these tests deliberately check both
/// halves: the counters are REAL even though nothing blocks on them yet.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('per-feature usage counters', () {
    test('remaining() starts at the full monthly limit for every feature', () async {
      final service = FreeTierEntitlementService.instance;
      for (final feature in FreeTierFeature.values) {
        expect(await service.remaining(feature), feature.monthlyLimit);
      }
    });

    test('recordUsed() decrements remaining() by exactly one, independently per feature', () async {
      final service = FreeTierEntitlementService.instance;
      await service.recordUsed(FreeTierFeature.lessonPlan);
      expect(await service.remaining(FreeTierFeature.lessonPlan), FreeTierFeature.lessonPlan.monthlyLimit - 1);
      // Recording a lesson plan must never touch the scheme/timetable counters.
      expect(await service.remaining(FreeTierFeature.schemeOfWork), FreeTierFeature.schemeOfWork.monthlyLimit);
      expect(await service.remaining(FreeTierFeature.timetableGeneration), FreeTierFeature.timetableGeneration.monthlyLimit);
    });

    test('remaining() never goes negative even if used past the limit', () async {
      final service = FreeTierEntitlementService.instance;
      // timetableGeneration's limit is 1 — use it twice.
      await service.recordUsed(FreeTierFeature.timetableGeneration);
      await service.recordUsed(FreeTierFeature.timetableGeneration);
      expect(await service.remaining(FreeTierFeature.timetableGeneration), 0);
    });

    test('canUse() always returns true while kFreeTierCapEnforced is false, regardless of usage', () async {
      // Real, deliberate assertion: if a future session flips
      // kFreeTierCapEnforced to true without updating this test, this
      // test should start failing loudly rather than silently passing —
      // that's the point of asserting the CURRENT (off) behavior
      // explicitly rather than skipping this case.
      expect(kFreeTierCapEnforced, isFalse, reason: 'If this changed on purpose, update the assertions below to match real enforcement.');
      final service = FreeTierEntitlementService.instance;
      for (var i = 0; i < FreeTierFeature.lessonPlan.monthlyLimit + 3; i++) {
        await service.recordUsed(FreeTierFeature.lessonPlan);
      }
      expect(await service.canUse(FreeTierFeature.lessonPlan), isTrue);
    });
  });

  group('scheme-of-work subject lock — real tracking, independent of the enforcement flag', () {
    // lockedSchemeSubjects() always tracks for real (unlike canUse/
    // isSchemeSubjectAllowed, which short-circuit to `true` while
    // kFreeTierCapEnforced is false) — these tests exercise that real
    // tracking directly rather than through the currently-gated
    // isSchemeSubjectAllowed(), which would pass even if the lock logic
    // underneath it were broken.
    test('no subjects locked yet', () async {
      expect(await FreeTierEntitlementService.instance.lockedSchemeSubjects(), isEmpty);
    });

    test('locking two different subjects fills both slots, in order', () async {
      final service = FreeTierEntitlementService.instance;
      await service.lockSchemeSubject('Mathematics');
      expect(await service.lockedSchemeSubjects(), ['Mathematics']);
      await service.lockSchemeSubject('English');
      expect(await service.lockedSchemeSubjects(), ['Mathematics', 'English']);
    });

    test('locking a third subject is a no-op — the two already locked stay exactly as they were', () async {
      final service = FreeTierEntitlementService.instance;
      await service.lockSchemeSubject('Mathematics');
      await service.lockSchemeSubject('English');
      await service.lockSchemeSubject('Biology'); // should not be added — both slots already taken
      expect(await service.lockedSchemeSubjects(), ['Mathematics', 'English']);
    });

    test('re-locking an already-locked subject does not duplicate it', () async {
      final service = FreeTierEntitlementService.instance;
      await service.lockSchemeSubject('Mathematics');
      await service.lockSchemeSubject('Mathematics');
      expect(await service.lockedSchemeSubjects(), ['Mathematics']);
    });

    test('isSchemeSubjectAllowed() is always true while kFreeTierCapEnforced is false, regardless of lock state', () async {
      expect(kFreeTierCapEnforced, isFalse, reason: 'If this changed on purpose, this test needs real lock-based assertions instead.');
      final service = FreeTierEntitlementService.instance;
      await service.lockSchemeSubject('Mathematics');
      await service.lockSchemeSubject('English');
      expect(await service.isSchemeSubjectAllowed('Biology'), isTrue); // would be false once enforcement is real
    });
  });
}
