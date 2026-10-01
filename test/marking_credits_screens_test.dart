import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:zambian_curriculum_app/models/marking_credits.dart';
import 'package:zambian_curriculum_app/screens/marking_credits_screen.dart';
import 'package:zambian_curriculum_app/screens/owner_finance_screen.dart';
import 'package:zambian_curriculum_app/services/marking_credits_service.dart';
import 'package:zambian_curriculum_app/services/marking_purchase_service.dart';

class _FakeCredits extends MarkingCreditsService {
  _FakeCredits({required this.config, required this.balance, this.history = const []});

  final MarkingCreditsConfig config;
  final CreditBalance balance;
  final List<CreditTransaction> history;

  @override
  Future<MarkingCreditsConfig> loadConfig() async => config;
  @override
  Future<String> currentUid() async => 'uid-test-123';
  @override
  Stream<CreditBalance> watchBalance() => Stream.value(balance);
  @override
  Future<List<CreditTransaction>> recentTransactions({int limit = 25}) async => history;
}

class _FakePurchases extends MarkingPurchaseService {
  _FakePurchases({this.available = true, this.products = const []});

  final bool available;
  final List<ProductDetails> products;
  final List<ProductDetails> bought = [];
  final StreamController<PurchaseOutcome> controller = StreamController<PurchaseOutcome>.broadcast();
  int recoverCalls = 0;

  @override
  Stream<PurchaseOutcome> get outcomes => controller.stream;
  @override
  Future<bool> get isAvailable async => available;
  @override
  Future<List<ProductDetails>> loadProducts(Set<String> ids) async => [for (final p in products) if (ids.contains(p.id)) p];
  @override
  Future<bool> buy(ProductDetails product) async {
    bought.add(product);
    return true;
  }

  @override
  Future<void> recoverPending() async => recoverCalls++;
}

ProductDetails _product(String id, String price) =>
    ProductDetails(id: id, title: id, description: '', price: price, rawPrice: 50, currencyCode: 'ZMW');

final _sept19 = DateTime.utc(2026, 9, 19, 10);
MarkingCreditsConfig _cfg(String mode) => MarkingCreditsConfig.fromMap({'mode': mode});

Future<void> _pump(
  WidgetTester tester, {
  required MarkingCreditsConfig config,
  CreditBalance balance = CreditBalance.empty,
  _FakePurchases? purchases,
  bool anonymous = false,
  Future<bool?> Function(BuildContext)? openLogin,
  List<CreditTransaction> history = const [],
}) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MarkingCreditsScreen(
      creditsService: _FakeCredits(config: config, balance: balance, history: history),
      purchaseService: purchases ?? _FakePurchases(),
      isAnonymous: () => anonymous,
      now: () => _sept19,
      openLogin: openLogin,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('MarkingCreditsScreen', () {
    testWidgets('credits OFF: says marking is free, sells nothing, still shows what it will cost and the coming 2027 change', (tester) async {
      await _pump(tester, config: _cfg('off'));

      expect(find.byKey(const Key('credits-off-note')), findsOneWidget);
      expect(find.textContaining('currently free'), findsOneWidget);
      expect(find.text('Buy credits'), findsNothing, reason: 'never sell credits while nothing is charged');
      expect(find.byKey(const Key('bundle-marking_bundle_k50')), findsNothing);

      expect(tester.widget<Text>(find.byKey(const Key('cost-stable'))).data, '1 credits');
      expect(tester.widget<Text>(find.byKey(const Key('cost-concise'))).data, '3.2 credits');
      expect(tester.widget<Text>(find.byKey(const Key('cost-keyed'))).data, '3.3 credits');
      final upcoming = tester.widget<Text>(find.byKey(const Key('upcoming-prices'))).data!;
      expect(upcoming, contains('1 January 2027'));
      expect(upcoming, contains('Concise Marking 6.4'));
      expect(upcoming, contains('Key-based Marking 6.5'));
    });

    testWidgets('SHADOW mode is described as a trial — nothing taken', (tester) async {
      await _pump(tester, config: _cfg('shadow'));
      expect(find.textContaining('nothing is taken'), findsOneWidget);
      expect(find.text('Buy credits'), findsNothing);
    });

    testWidgets('ENFORCED, signed in: shows the combined balance, the bundles with Google Play\'s own prices, and pages-per-bundle', (tester) async {
      final purchases = _FakePurchases(products: [
        _product('marking_bundle_k50', 'ZMW 50.00'),
        _product('marking_bundle_k100', 'ZMW 100.00'),
        _product('marking_bundle_k150', 'ZMW 150.00'),
      ]);
      await _pump(
        tester,
        config: _cfg('enforced'),
        balance: const CreditBalance(freeCredits: 7.2, purchasedCredits: 87, freePeriod: '2026-09'),
        purchases: purchases,
      );

      expect(tester.widget<Text>(find.byKey(const Key('spendable-credits'))).data, '94.2 credits');
      expect(find.text('Buy credits'), findsOneWidget);
      expect(find.text('87 credits'), findsOneWidget);
      expect(find.text('178 credits'), findsOneWidget);
      expect(find.text('268 credits'), findsOneWidget);
      expect(find.text('ZMW 50.00'), findsOneWidget);
      // 87 credits / 3.2 per Concise page = 27 pages
      expect(find.textContaining('27 pages Concise'), findsOneWidget);
      expect(find.textContaining('87 pages Stable'), findsOneWidget);
      expect(purchases.recoverCalls, 1, reason: 'paid-but-uncredited purchases are recovered when the screen opens');
    });

    testWidgets('a new month shows the fresh 10 free credits, not last month\'s leftovers stacked on top', (tester) async {
      await _pump(
        tester,
        config: _cfg('enforced'),
        balance: const CreditBalance(freeCredits: 15, purchasedCredits: 50, freePeriod: '2026-08'),
      );
      expect(tester.widget<Text>(find.byKey(const Key('spendable-credits'))).data, '60 credits');
    });

    testWidgets('tapping a bundle starts the Google Play purchase for THAT product', (tester) async {
      final purchases = _FakePurchases(products: [_product('marking_bundle_k100', 'ZMW 100.00'), _product('marking_bundle_k50', 'ZMW 50.00')]);
      await _pump(tester, config: _cfg('enforced'), purchases: purchases);

      await tester.tap(find.text('ZMW 100.00'));
      await tester.pump();
      expect(purchases.bought.map((p) => p.id), ['marking_bundle_k100']);
    });

    testWidgets('an ANONYMOUS teacher is sent to sign in instead of buying — and no purchase starts', (tester) async {
      final purchases = _FakePurchases(products: [_product('marking_bundle_k50', 'ZMW 50.00')]);
      var loginOpened = 0;
      await _pump(
        tester,
        config: _cfg('enforced'),
        purchases: purchases,
        anonymous: true,
        openLogin: (_) async {
          loginOpened++;
          return false;
        },
      );
      expect(find.textContaining('Sign in with your phone number or email before buying'), findsOneWidget);

      await tester.tap(find.text('ZMW 50.00'));
      await tester.pumpAndSettle();
      expect(loginOpened, 1);
      expect(purchases.bought, isEmpty);
    });

    testWidgets('Play unavailable / products not set up: explains instead of showing dead buttons that crash', (tester) async {
      await _pump(tester, config: _cfg('enforced'), purchases: _FakePurchases(available: false));
      expect(find.textContaining("Purchases aren't available right now"), findsOneWidget);
    });

    testWidgets('a purchase outcome from the store is shown to the teacher', (tester) async {
      final purchases = _FakePurchases(products: [_product('marking_bundle_k50', 'ZMW 50.00')]);
      await _pump(tester, config: _cfg('enforced'), purchases: purchases);
      purchases.controller.add(const PurchaseOutcome(PurchaseOutcomeKind.credited, 'Added 87 marking credits.', credits: 87));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Added 87 marking credits.'), findsOneWidget);
    });

    testWidgets('the owner finance tools are NOT on the phone at all - they live in the web admin dashboard', (tester) async {
      await _pump(tester, config: _cfg('enforced'));
      expect(find.text('Owner finance tools'), findsNothing);
      expect(find.textContaining('Owner finance'), findsNothing);
    });

    testWidgets('the account id (needed to register as owner) is shown', (tester) async {
      await _pump(tester, config: _cfg('off'));
      expect(tester.widget<Text>(find.byKey(const Key('account-id'))).data, 'uid-test-123');
    });

    testWidgets('recent activity lists spends and purchases', (tester) async {
      await _pump(
        tester,
        config: _cfg('enforced'),
        history: const [
          CreditTransaction(type: 'purchase', credits: 87),
          CreditTransaction(type: 'spend', credits: -12.8, engine: 'concise', pages: 4),
        ],
      );
      expect(find.text('Bundle purchased'), findsOneWidget);
      expect(find.text('Marking (Concise), 4 pages'), findsOneWidget);
      expect(find.text('+87'), findsOneWidget);
      expect(find.text('-12.8'), findsOneWidget);
    });
  });

  group('showOutOfCreditsDialog', () {
    testWidgets('states exactly what is needed vs available, and reassures that nothing was charged', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showOutOfCreditsDialog(
                context,
                const InsufficientCreditsException(requiredCredits: 12.8, availableCredits: 3, message: 'x'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Out of marking credits'), findsOneWidget);
      expect(find.textContaining('needs 12.8 credits and you have 3'), findsOneWidget);
      expect(find.textContaining('nothing was charged'), findsOneWidget);
      expect(find.text('Get credits'), findsOneWidget);
    });
  });

  group('OwnerFinanceScreen', () {
    Map<String, Object?> summary({int? fxDays = 10, bool fxStale = false, bool crossed = false, double? measured = 0.0125}) => {
          'revenue': {
            'rolling12mKwacha': crossed ? 850000 : 200000,
            'thresholdKwacha': 800000,
            'remainingKwacha': crossed ? 0 : 600000,
            'percentOfThreshold': crossed ? 106.25 : 25,
            'vatThresholdCrossed': crossed,
            'basis': 'Configured list price of verified purchases, not the amount Google actually charged.',
          },
          'fx': {'rate': 24.5, 'updatedAtMs': 1, 'daysSinceUpdate': fxDays, 'stale': fxStale},
          'usage': {
            'concise': {
              'attempts': 10, 'successes': 8, 'pagesSuccessful': 32, 'unpricedAttempts': 0,
              'measuredCostPerPageUsd': measured, 'modeledCostPerPageUsd': 0.0083,
              'measuredVsModeled': measured == null ? null : measured / 0.0083,
            },
            'stable': {'attempts': 0, 'successes': 0, 'pagesSuccessful': 0, 'measuredCostPerPageUsd': null, 'modeledCostPerPageUsd': 0.0026, 'measuredVsModeled': null},
            'keyed': {'attempts': 0, 'successes': 0, 'pagesSuccessful': 0, 'measuredCostPerPageUsd': null, 'modeledCostPerPageUsd': 0.0085, 'measuredVsModeled': null},
          },
          'features': {
            'lessonPlan': {'requests': 12, 'successes': 10, 'calls': 10, 'creditsPerUse': 10, 'measuredCostPerUseUsd': 0.04, 'impliedCostPerCreditUsd': 0.004},
            'teachingNotes': {'requests': 20, 'successes': 20, 'calls': 20, 'creditsPerUse': 8, 'measuredCostPerUseUsd': 0.018, 'impliedCostPerCreditUsd': 0.00225},
            'schemeOfWork': {'requests': 0, 'successes': 0, 'calls': 0, 'creditsPerUse': 10, 'measuredCostPerUseUsd': null, 'impliedCostPerCreditUsd': null},
          },
          'targetCostPerCreditUsd': 0.0026,
          'config': {
            'mode': 'enforced',
            'featuresMode': 'shadow',
            'adPasses': {'enabled': false, 'perDayCap': 5, 'ttlHours': 24},
            'freeMonthlyCredits': 10,
            'activeWeights': {'effectiveFrom': '2026-09-19T00:00:00+02:00', 'stable': 1, 'concise': 3.2, 'keyed': 3.3},
            'nextWeights': {'effectiveFrom': '2027-01-01T00:00:00+02:00', 'stable': 1, 'concise': 6.4, 'keyed': 6.5},
            'activeScenario': 'scenario1',
            'bundles': {
              'marking_bundle_k50': {'credits': 87, 'listPrice': {'amount': 50, 'currency': 'ZMW'}},
            },
          },
        };

    Future<void> pumpOwner(WidgetTester tester, Map<String, Object?> data, {Future<void> Function(double)? saveRate}) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: OwnerFinanceScreen(fetchSummary: () async => data, saveRate: saveRate)));
      await tester.pumpAndSettle();
    }

    testWidgets('shows revenue, distance to the K800,000 threshold, measured vs modelled cost, and the live config', (tester) async {
      await pumpOwner(tester, summary());
      expect(tester.widget<Text>(find.byKey(const Key('rolling-revenue'))).data, 'K200,000');
      expect(tester.widget<Text>(find.byKey(const Key('threshold-line'))).data, contains('K600,000 to go until the K800,000 VAT threshold'));
      final cost = tester.widget<Text>(find.byKey(const Key('cost-line-concise'))).data!;
      expect(cost, contains(r'Measured $0.0125'));
      expect(cost, contains(r'modelled $0.0083'));
      expect(cost, contains('1.51×'));
      expect(find.text('Running over the model — worth a look at pricing.'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('cost-line-stable'))).data, contains('No marking data yet'));
      expect(tester.widget<Text>(find.byKey(const Key('config-mode'))).data, 'Credits mode: enforced');
      expect(find.textContaining('Concise 6.4'), findsOneWidget, reason: 'the coming 2027 weights are visible');
    });

    testWidgets('per-feature cost: measured cost per use and per credit, an under-priced feature is flagged, one with no data says so', (tester) async {
      await pumpOwner(tester, summary());
      final lesson = tester.widget<Text>(find.byKey(const Key('feature-line-lessonPlan'))).data!;
      expect(lesson, contains(r'$0.0400 per use'));
      expect(lesson, contains('10 credits'));
      expect(lesson, contains(r'$0.0040/credit'));
      expect(find.text('Costs more than it charges — consider raising its credits.'), findsOneWidget, reason: 'only the lesson plan (0.0040 > 1.25 x 0.0026)');
      expect(tester.widget<Text>(find.byKey(const Key('feature-line-teachingNotes'))).data, contains(r'$0.0022/credit'));
      expect(tester.widget<Text>(find.byKey(const Key('feature-line-schemeOfWork'))).data, contains('No usage yet'));
      expect(tester.widget<Text>(find.byKey(const Key('config-features-mode'))).data, 'Other AI features mode: shadow');
      expect(tester.widget<Text>(find.byKey(const Key('config-ad-passes'))).data, 'Ad passes: off');
    });

    testWidgets('crossing the threshold is stated plainly', (tester) async {
      await pumpOwner(tester, summary(crossed: true));
      expect(tester.widget<Text>(find.byKey(const Key('threshold-line'))).data, 'VAT threshold of K800,000 has been reached.');
    });

    testWidgets('exchange rate: a fresh rate shows no warning', (tester) async {
      await pumpOwner(tester, summary(fxDays: 10, fxStale: false));
      expect(find.byKey(const Key('fx-stale')), findsNothing);
      expect(tester.widget<Text>(find.byKey(const Key('fx-age'))).data, 'Last updated 10 days ago.');
    });

    testWidgets('exchange rate: one over 60 days old is flagged visually', (tester) async {
      await pumpOwner(tester, summary(fxDays: 61, fxStale: true));
      expect(find.byKey(const Key('fx-stale')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('fx-stale'))).data, contains('over 60 days'));
    });

    testWidgets('a never-updated rate is flagged as such', (tester) async {
      await pumpOwner(tester, summary(fxDays: null, fxStale: true));
      expect(tester.widget<Text>(find.byKey(const Key('fx-age'))).data, contains('Never updated'));
      expect(find.byKey(const Key('fx-stale')), findsOneWidget);
    });

    testWidgets('updating the rate sends the entered value', (tester) async {
      double? saved;
      await pumpOwner(tester, summary(), saveRate: (r) async => saved = r);
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '26.75');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, 26.75);
    });

    testWidgets('an obviously wrong rate is not sent', (tester) async {
      double? saved;
      await pumpOwner(tester, summary(), saveRate: (r) async => saved = r);
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('Exchange rate'), findsWidgets, reason: 'the dialog stays open');
    });

    testWidgets('a refused request (non-owner) shows the server\'s message with a retry, not a crash', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: OwnerFinanceScreen(fetchSummary: () async => throw StateError('boom'))));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not load the finance summary'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}
