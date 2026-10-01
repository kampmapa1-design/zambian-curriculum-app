import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/marking_credits.dart';
import 'package:zambian_curriculum_app/services/marking_credits_service.dart';
import 'package:zambian_curriculum_app/services/marking_purchase_service.dart';

void main() {
  group('MarkingCreditsConfig.fromMap', () {
    test('missing or garbage config falls back to the safe defaults — mode OFF, so nothing can start charging', () {
      for (final raw in [null, 42, 'x', <Object?>[]]) {
        final c = MarkingCreditsConfig.fromMap(raw);
        expect(c.mode, 'off');
        expect(c.isEnforced, isFalse);
        expect(c.freeMonthlyCredits, 10);
        expect(c.weightSets, hasLength(2));
      }
    });

    test('valid remote values override the defaults; invalid ones are ignored', () {
      final c = MarkingCreditsConfig.fromMap({'mode': 'enforced', 'freeMonthlyCredits': 30});
      expect(c.isEnforced, isTrue);
      expect(c.freeMonthlyCredits, 30);
      final bad = MarkingCreditsConfig.fromMap({'mode': 'yes please', 'freeMonthlyCredits': -5});
      expect(bad.mode, 'off');
      expect(bad.freeMonthlyCredits, 10);
    });

    test('weight sets missing an engine, with a bad date, or a zero weight are dropped; the rest are date-sorted', () {
      final c = MarkingCreditsConfig.fromMap({
        'weightSets': [
          {'effectiveFrom': '2027-01-01T00:00:00+02:00', 'weights': {'stable': 1, 'concise': 6.4, 'keyed': 6.5}},
          {'effectiveFrom': 'not a date', 'weights': {'stable': 1, 'concise': 1, 'keyed': 1}},
          {'effectiveFrom': '2026-10-01T00:00:00+02:00', 'weights': {'stable': 1, 'concise': 3}},
          {'effectiveFrom': '2026-11-01T00:00:00+02:00', 'weights': {'stable': 0, 'concise': 3, 'keyed': 3}},
          {'effectiveFrom': '2026-06-01T00:00:00+02:00', 'weights': {'stable': 1, 'concise': 3.2, 'keyed': 3.3}},
        ],
      });
      expect(c.weightSets.map((s) => s.weights.concise), [3.2, 6.4]);
    });

    test('bundles: invalid products dropped, explicit null scenario preserved, active falls back to scenario1', () {
      final c = MarkingCreditsConfig.fromMap({
        'bundles': {
          'activeScenario': 'scenario2',
          'scenarios': {
            'scenario1': {
              'good': {'credits': 100, 'listPrice': {'amount': 50, 'currency': 'ZMW'}},
              'noCredits': {'listPrice': {'amount': 50, 'currency': 'ZMW'}},
              'zeroPrice': {'credits': 10, 'listPrice': {'amount': 0, 'currency': 'ZMW'}},
            },
            'scenario2': null,
          },
        },
      });
      expect(c.scenarios['scenario2'], isNull);
      expect(c.activeBundles.map((b) => b.productId), ['good'], reason: 'an undefined active scenario falls back to scenario1');
    });

    test('the default bundles are the three Scenario 1 sizes: K50=87, K100=178, K150=268', () {
      final b = MarkingCreditsConfig.defaults.activeBundles;
      expect(b.map((x) => (x.productId, x.credits, x.listAmount)), [
        ('marking_bundle_k50', 87.0, 50.0),
        ('marking_bundle_k100', 178.0, 100.0),
        ('marking_bundle_k150', 268.0, 150.0),
      ]);
    });
  });

  group('weights follow the effective date (display only — the server decides the real price)', () {
    final c = MarkingCreditsConfig.defaults;
    final jan1Cat = DateTime.parse('2027-01-01T00:00:00+02:00'); // = 2026-12-31 22:00 UTC

    test('2026 prices before 1 Jan 2027: Stable 1, Concise 3.2, Key-based 3.3', () {
      final w = c.weightSetAt(DateTime.utc(2026, 11, 15)).weights;
      expect((w.stable, w.concise, w.keyed), (1.0, 3.2, 3.3));
    });

    test('the switch happens at exactly midnight Zambia time — one millisecond earlier is still the old price', () {
      expect(c.weightSetAt(jan1Cat.subtract(const Duration(milliseconds: 1))).weights.concise, 3.2);
      final w = c.weightSetAt(jan1Cat).weights;
      expect((w.stable, w.concise, w.keyed), (1.0, 6.4, 6.5));
    });

    test('a coming price change is reported until it starts', () {
      expect(c.upcomingWeightSet(DateTime.utc(2026, 9, 19))?.weights.concise, 6.4);
      expect(c.upcomingWeightSet(DateTime.utc(2027, 1, 2)), isNull);
    });

    test('cost of a script: 4 Concise pages = 12.8 credits; 3 Key-based pages = 9.9, not 9.899999999999999', () {
      final now = DateTime.utc(2026, 9, 19);
      expect(c.costFor(MarkingEngineKind.concise, 4, now), 12.8);
      expect(3.3 * 3, isNot(9.9), reason: 'the floating-point trap this guards against');
      expect(c.costFor(MarkingEngineKind.keyed, 3, now), 9.9);
      expect(c.costFor(MarkingEngineKind.stable, 4, now), 4.0);
    });
  });

  group('periodKeyCat — Zambian calendar months (UTC+2, no DST)', () {
    test('23:59:59 on 31 Dec is still December; the next second is January', () {
      expect(periodKeyCat(DateTime.utc(2026, 12, 31, 21, 59, 59)), '2026-12');
      expect(periodKeyCat(DateTime.utc(2026, 12, 31, 22, 0, 0)), '2027-01');
    });
    test('works from a local-time DateTime too', () {
      expect(periodKeyCat(DateTime.parse('2026-09-30T23:30:00Z').toLocal()), '2026-10');
    });
  });

  group('CreditBalance', () {
    final config = MarkingCreditsConfig.defaults; // 10 free per month
    final sept = DateTime.utc(2026, 9, 19, 10);

    test('same month: free + purchased', () {
      const b = CreditBalance(freeCredits: 7.2, purchasedCredits: 50, freePeriod: '2026-09');
      expect(b.spendable(config, sept), closeTo(57.2, 1e-9));
    });

    test('a new month shows the fresh allowance, NOT last month\'s leftovers added on (no roll-over)', () {
      const b = CreditBalance(freeCredits: 15, purchasedCredits: 50, freePeriod: '2026-08');
      expect(b.spendable(config, sept), 60, reason: '10 fresh free + 50 bought, not 15 + 10 + 50');
      expect(b.freeAvailable(config, sept), 10);
    });

    test('a teacher with no ledger yet is shown the allowance they will be granted', () {
      expect(CreditBalance.empty.spendable(config, sept), 10);
    });

    test('reads the server\'s integer units', () {
      final b = CreditBalance.fromMap({'freeUnits': 7200, 'purchasedUnits': 87000, 'freePeriod': '2026-09'});
      expect((b.freeCredits, b.purchasedCredits), (7.2, 87.0));
      expect(CreditBalance.fromMap({'freeUnits': 'lots'}).freeCredits, 0);
    });
  });

  group('CreditTransaction descriptions', () {
    test('are teacher-readable', () {
      expect(CreditTransaction.fromMap({'type': 'spend', 'units': -12800, 'engine': 'concise', 'pages': 4}).description, 'Marking (Concise), 4 pages');
      expect(CreditTransaction.fromMap({'type': 'spend', 'units': -1000, 'engine': 'stable', 'pages': 1}).description, 'Marking (Stable), 1 page');
      expect(CreditTransaction.fromMap({'type': 'purchase', 'units': 87000}).credits, 87);
      expect(CreditTransaction.fromMap({'type': 'free_grant', 'units': 20000}).description, 'Monthly free credits');
      expect(CreditTransaction.fromMap({'type': 'shadow_spend', 'units': -3200}).description, contains('not charged'));
    });
  });

  group('insufficientCreditsFrom — only the server\'s specific refusal becomes the typed exception', () {
    test('the real refusal is recognised, with the exact numbers', () {
      final e = insufficientCreditsFrom(
        code: 'failed-precondition',
        details: {'code': 'insufficient_credits', 'requiredCredits': 12.8, 'availableCredits': 3},
        message: 'Not enough marking credits',
      );
      expect(e, isNotNull);
      expect((e!.requiredCredits, e.availableCredits), (12.8, 3.0));
    });

    test('other failures are NOT mistaken for it', () {
      expect(insufficientCreditsFrom(code: 'internal', details: {'code': 'insufficient_credits'}), isNull);
      expect(insufficientCreditsFrom(code: 'failed-precondition', details: {'code': 'sign_in_required'}), isNull);
      expect(insufficientCreditsFrom(code: 'failed-precondition', details: null), isNull);
      expect(insufficientCreditsFrom(code: 'failed-precondition', details: 'insufficient_credits'), isNull);
    });
  });

  group('CreditsCharged.fromResponse', () {
    test('parses the server\'s credits block, and ignores a missing one', () {
      final c = CreditsCharged.fromResponse({'mode': 'enforced', 'charged': 12.8, 'duplicate': false, 'balance': 7.2});
      expect((c!.charged, c.balance, c.duplicate), (12.8, 7.2, false));
      expect(CreditsCharged.fromResponse(null), isNull);
      expect(CreditsCharged.fromResponse({'nope': 1}), isNull);
    });
  });

  group('account id parity with the server (a mismatch would make every purchase unredeemable)', () {
    test('matches the vectors computed by the Cloud Function\'s own obfuscatedAccountId', () {
      expect(obfuscatedAccountIdFor('Zk3pQ9vR2mXaLd8YbN4tUcHe7Sw1'), '96ce7310cfcaaa6bd2bf0bb9a1654ee2c1edd2a5');
      expect(obfuscatedAccountIdFor('uid-with-ünïcode'), 'f456ea52a220d91655a684109001a1c06699ff86');
    });
    test('never contains the raw uid and fits Play\'s 64-character limit', () {
      final id = obfuscatedAccountIdFor('abc123');
      expect(id, isNot(contains('abc123')));
      expect(id.length, lessThanOrEqualTo(64));
    });
  });

  group('MarkingRequestIds', () {
    setUp(MarkingRequestIds.resetForTest);

    test('the same key gives the same id until cleared, then a new one', () {
      final a = MarkingRequestIds.forKey('script:1');
      expect(MarkingRequestIds.forKey('script:1'), a);
      MarkingRequestIds.clear('script:1');
      expect(MarkingRequestIds.forKey('script:1'), isNot(a));
    });
    test('different keys differ, and every id is long enough for the server to accept (8-128 chars)', () {
      final a = MarkingRequestIds.forKey('a');
      final b = MarkingRequestIds.forKey('b');
      expect(a, isNot(b));
      for (final id in [a, b]) {
        expect(id.length, inInclusiveRange(8, 128));
      }
    });
  });

  group('CreditRedeemException.fromCode', () {
    test('classifies refusals the way the purchase flow needs', () {
      expect(CreditRedeemException.fromCode('failed-precondition', {'code': 'sign_in_required'}, 'x').needsSignIn, isTrue);
      expect(CreditRedeemException.fromCode('failed-precondition', {'code': 'verification_unavailable'}, 'x').retryable, isTrue);
      expect(CreditRedeemException.fromCode('failed-precondition', {'code': 'purchase_pending'}, 'x').retryable, isTrue);
      expect(CreditRedeemException.fromCode('unavailable', null, 'x').retryable, isTrue);
      final permanent = CreditRedeemException.fromCode('permission-denied', null, 'different account');
      expect((permanent.retryable, permanent.needsSignIn), (false, false));
    });
  });

  group('PurchaseProcessor — consume ONLY after the server has credited', () {
    const purchase = PurchaseInfo(productId: 'marking_bundle_k50', purchaseToken: 'token-abc-123', status: 'purchased');

    test('success: credited, then consumed', () async {
      final consumed = <String>[];
      final p = PurchaseProcessor(
        redeem: (id, token) async => const RedeemOutcome(creditsGranted: 87, duplicate: false, balance: 87),
        consume: (x) async => consumed.add(x.purchaseToken),
      );
      final o = await p.process(purchase);
      expect(o?.kind, PurchaseOutcomeKind.credited);
      expect(o?.credits, 87);
      expect(o?.message, 'Added 87 marking credits.');
      expect(consumed, ['token-abc-123']);
    });

    test('a re-delivered purchase (server says duplicate) is reported as already credited, and still consumed', () async {
      final consumed = <String>[];
      final p = PurchaseProcessor(
        redeem: (id, token) async => const RedeemOutcome(creditsGranted: 0, duplicate: true),
        consume: (x) async => consumed.add(x.purchaseToken),
      );
      expect((await p.process(purchase))?.kind, PurchaseOutcomeKind.alreadyCredited);
      expect(consumed, hasLength(1));
    });

    test('EVERY server refusal leaves the purchase UN-consumed (so it is retried, never lost)', () async {
      for (final failure in [
        const CreditRedeemException('sign in', needsSignIn: true),
        const CreditRedeemException('later', retryable: true),
        const CreditRedeemException('nope'),
      ]) {
        final consumed = <String>[];
        final p = PurchaseProcessor(redeem: (a, b) async => throw failure, consume: (x) async => consumed.add(x.purchaseToken));
        final o = await p.process(purchase);
        expect(consumed, isEmpty, reason: 'consuming before crediting would take the money and lose the credits');
        expect(o?.kind, failure.needsSignIn ? PurchaseOutcomeKind.needsSignIn : failure.retryable ? PurchaseOutcomeKind.pending : PurchaseOutcomeKind.failed);
      }
    });

    test('credited but the consume call fails: still reported as credited (a later recovery pass retries the consume)', () async {
      final p = PurchaseProcessor(
        redeem: (a, b) async => const RedeemOutcome(creditsGranted: 87, duplicate: false),
        consume: (x) async => throw StateError('billing service disconnected'),
      );
      expect((await p.process(purchase))?.kind, PurchaseOutcomeKind.credited);
    });

    test('pending / cancelled / errored purchases never reach the server', () async {
      var redeemed = 0;
      final p = PurchaseProcessor(redeem: (a, b) async { redeemed++; return const RedeemOutcome(creditsGranted: 1, duplicate: false); }, consume: (x) async {});
      for (final status in ['pending', 'canceled', 'error']) {
        final o = await p.process(PurchaseInfo(productId: 'x', purchaseToken: 'token-$status-1234', status: status, errorMessage: 'card declined'));
        expect(o, isNotNull);
      }
      expect(redeemed, 0);
    });

    test('the same token delivered twice at once is redeemed once', () async {
      var redeemed = 0;
      final p = PurchaseProcessor(
        redeem: (a, b) async {
          redeemed++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return const RedeemOutcome(creditsGranted: 87, duplicate: false);
        },
        consume: (x) async {},
      );
      final results = await Future.wait([p.process(purchase), p.process(purchase)]);
      expect(redeemed, 1);
      expect(results.where((r) => r != null), hasLength(1));
    });
  });
}
