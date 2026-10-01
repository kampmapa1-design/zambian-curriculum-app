import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/marking_credits.dart';
import 'package:zambian_curriculum_app/services/marking_credits_service.dart';
import 'package:zambian_curriculum_app/services/metered_call.dart';

void main() {
  group('withMeteringFields', () {
    test('adds a request id to a map payload without touching anything else', () {
      final out = withMeteringFields({'topic': 'Fractions', 'grade': 7}, requestId: 'req-1') as Map;
      expect(out, {'topic': 'Fractions', 'grade': 7, 'requestId': 'req-1'});
    });

    test('a null payload becomes a request-id-only map', () {
      expect(withMeteringFields(null, requestId: 'req-2'), {'requestId': 'req-2'});
    });

    test('payWith:ad is added ONLY when the teacher chose it', () {
      expect((withMeteringFields({'a': 1}, requestId: 'r') as Map).containsKey('payWith'), isFalse);
      expect((withMeteringFields({'a': 1}, requestId: 'r', payWithAd: true) as Map)['payWith'], 'ad');
    });

    test('the caller\'s own map is not mutated', () {
      final original = {'a': 1};
      withMeteringFields(original, requestId: 'r');
      expect(original, {'a': 1});
    });

    test('a non-map payload (a list) passes through unchanged', () {
      expect(withMeteringFields([1, 2, 3], requestId: 'r'), [1, 2, 3]);
    });
  });

  group('AdPassPreference', () {
    test('applies to exactly ONE generation, then resets', () {
      final p = AdPassPreference.instance;
      expect(p.takePreferAd(), isFalse);
      p.preferAdForNextUse();
      expect(p.takePreferAd(), isTrue);
      expect(p.takePreferAd(), isFalse);
    });
  });

  group('OutOfCreditsNotifier', () {
    const reason = InsufficientCreditsException(requiredCredits: 10, availableCredits: 2, message: 'x', feature: 'lessonPlan');

    test('announces a refusal once, and suppresses a repeat within 8 seconds (no stacked dialogs)', () async {
      final seen = <InsufficientCreditsException>[];
      final sub = OutOfCreditsNotifier.instance.stream.listen(seen.add);
      final t0 = DateTime.utc(2030, 1, 1, 12);
      OutOfCreditsNotifier.instance.notify(reason, now: t0);
      OutOfCreditsNotifier.instance.notify(reason, now: t0.add(const Duration(seconds: 3)));
      OutOfCreditsNotifier.instance.notify(reason, now: t0.add(const Duration(seconds: 9)));
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2));
      await sub.cancel();
    });
  });

  group('MeteredCallable', () {
    Future<HttpsCallableResult<T>> refusing<T>([dynamic parameters]) async => throw FirebaseFunctionsException(
          message: 'Not enough credits',
          code: 'failed-precondition',
          details: {'code': 'insufficient_credits', 'feature': 'lessonPlan', 'requiredCredits': 10, 'availableCredits': 4, 'adPassEligible': true},
        );

    test('a refusal becomes the typed exception, with the feature and ad eligibility, and raises the app-wide dialog', () async {
      final notified = <InsufficientCreditsException>[];
      final sub = OutOfCreditsNotifier.instance.stream.listen(notified.add);
      OutOfCreditsNotifier.instance.notify(
        const InsufficientCreditsException(requiredCredits: 0, availableCredits: 0, message: 'prime the throttle'),
        now: DateTime.utc(2000),
      ); // start from a known throttle state well in the past
      await Future<void>.delayed(Duration.zero);
      notified.clear();

      Object? caught;
      try {
        await MeteredCallable(refusing).call<Object?>({'topic': 'x'});
      } catch (e) {
        caught = e;
      }
      await Future<void>.delayed(Duration.zero);
      expect(caught, isA<InsufficientCreditsException>());
      final e = caught! as InsufficientCreditsException;
      expect((e.feature, e.requiredCredits, e.availableCredits, e.adPassEligible), ('lessonPlan', 10.0, 4.0, true));
      expect(notified, hasLength(1));
      await sub.cancel();
    });

    test('with notify off (a quiet call site) the typed exception is still thrown but no dialog is raised', () async {
      final notified = <InsufficientCreditsException>[];
      final sub = OutOfCreditsNotifier.instance.stream.listen(notified.add);
      OutOfCreditsNotifier.instance.notify(
        const InsufficientCreditsException(requiredCredits: 0, availableCredits: 0, message: 'reset'),
        now: DateTime.utc(2001),
      );
      await Future<void>.delayed(Duration.zero);
      notified.clear();
      await expectLater(MeteredCallable(refusing, notifyOnOutOfCredits: false).call<Object?>({}), throwsA(isA<InsufficientCreditsException>()));
      await Future<void>.delayed(Duration.zero);
      expect(notified, isEmpty);
      await sub.cancel();
    });

    test('every other server error passes through UNCHANGED (never mistaken for a credits problem)', () async {
      Future<HttpsCallableResult<T>> broken<T>([dynamic parameters]) async =>
          throw FirebaseFunctionsException(message: 'Failed to generate', code: 'internal');
      await expectLater(
        MeteredCallable(broken).call<Object?>({}),
        throwsA(isA<FirebaseFunctionsException>().having((e) => e.code, 'code', 'internal')),
      );
    });

    test('the payload actually sent carries a fresh request id, different for each call', () async {
      final sent = <Object?>[];
      Future<HttpsCallableResult<T>> capture<T>([dynamic parameters]) async {
        sent.add(parameters);
        throw FirebaseFunctionsException(message: 'stop', code: 'internal');
      }

      final c = MeteredCallable(capture);
      for (var i = 0; i < 2; i++) {
        try {
          await c.call<Object?>({'topic': 'x'});
        } catch (_) {}
      }
      final ids = [for (final s in sent) (s! as Map)['requestId'] as String];
      expect(ids, hasLength(2));
      expect(ids[0], isNot(ids[1]));
      expect(ids.every((id) => id.length >= 8 && id.length <= 128), isTrue, reason: 'the server ignores ids outside 8-128 chars');
      expect(sent.every((s) => (s! as Map)['topic'] == 'x'), isTrue);
    });
  });

  group('the server\'s feature refusal is parsed', () {
    test('feature and ad eligibility come through; marking\'s refusal (no feature) stays feature-less', () {
      final f = insufficientCreditsFrom(
        code: 'failed-precondition',
        details: {'code': 'insufficient_credits', 'feature': 'schemeOfWork', 'requiredCredits': 10, 'availableCredits': 0, 'adPassEligible': false},
      )!;
      expect((f.feature, f.adPassEligible), ('schemeOfWork', false));
      final m = insufficientCreditsFrom(code: 'failed-precondition', details: {'code': 'insufficient_credits', 'requiredCredits': 12.8, 'availableCredits': 3})!;
      expect((m.feature, m.adPassEligible), (null, false));
    });
  });

  group('credit history wording for features', () {
    test('a feature spend, an ad-paid use and a trial run read naturally', () {
      expect(CreditTransaction.fromMap({'type': 'spend', 'units': -10000, 'feature': 'lessonPlan', 'kind': 'feature'}).description, 'Lesson plan');
      expect(CreditTransaction.fromMap({'type': 'ad_pass_spend', 'units': 0, 'feature': 'teachingNotes'}).description, 'Set of teaching notes (paid with an ad)');
      expect(CreditTransaction.fromMap({'type': 'shadow_spend', 'units': -4000, 'feature': 'transcription'}).description, 'Transcription (trial run, not charged)');
    });
    test('marking history is unchanged', () {
      expect(CreditTransaction.fromMap({'type': 'spend', 'units': -12800, 'engine': 'concise', 'pages': 4}).description, 'Marking (Concise), 4 pages');
    });
  });
}
