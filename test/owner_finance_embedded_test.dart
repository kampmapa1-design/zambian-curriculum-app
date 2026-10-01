import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/screens/owner_finance_screen.dart';

Map<String, Object?> _summary() => {
      'revenue': {'rolling12mKwacha': 0, 'thresholdKwacha': 800000, 'remainingKwacha': 800000, 'percentOfThreshold': 0, 'vatThresholdCrossed': false, 'basis': ''},
      'fx': {'rate': 20, 'updatedAtMs': null, 'daysSinceUpdate': null, 'stale': true},
      'usage': {},
      'features': {},
      'targetCostPerCreditUsd': 0.0026,
      'config': {'mode': 'off', 'featuresMode': 'off', 'adPasses': {'enabled': false}, 'freeMonthlyCredits': 10, 'activeWeights': {}, 'bundles': {}},
    };

void main() {
  testWidgets('embedded in the web dashboard: no app bar of its own, a heading instead, and a wide-screen-safe width', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: OwnerFinanceScreen(embedded: true, fetchSummary: () async => _summary())));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Owner finance'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    // On a 1600px-wide desktop window the cards stay within a readable column.
    final cardWidth = tester.getSize(find.byKey(const Key('rolling-revenue')).first).width;
    expect(cardWidth, lessThan(900));
    final listWidth = tester.getSize(find.byType(ListView)).width;
    expect(listWidth, lessThanOrEqualTo(900));
  });

  testWidgets('standalone it still has its own app bar', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: OwnerFinanceScreen(fetchSummary: () async => _summary())));
    await tester.pumpAndSettle();
    expect(find.text('Owner finance'), findsOneWidget); // the app bar title
  });
}
