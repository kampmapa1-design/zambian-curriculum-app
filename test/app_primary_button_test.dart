// Aesthetics pass, Stage H (2026-09-27): AppPrimaryButton — the dual-shadow
// "pressable" primary CTA. Rest state (raised, highlight+shadow), pressed
// state (shadows pulled inward/shrunk, near-transparent instead of just
// present/absent), disabled/loading behavior, and real tap wiring.
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/widgets/app_primary_button.dart';

BoxDecoration _decorationOf(WidgetTester tester) =>
    tester.widget<Container>(find.byType(Container)).decoration as BoxDecoration;

Future<void> main() async {
  testWidgets('at rest: a highlight plus a two-layer shadow, fully raised', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppPrimaryButton(label: 'Generate', icon: Icons.auto_awesome, onPressed: () {})),
    ));

    final shadows = _decorationOf(tester).boxShadow!;
    expect(shadows, hasLength(3), reason: 'highlight + ambient + contact');
    final highlight = shadows[0];
    expect(highlight.color.a, greaterThan(0), reason: 'the upper-left highlight is visible at rest');
    expect(highlight.offset.dx, lessThan(0), reason: 'highlight sits toward the upper-LEFT');
    expect(highlight.offset.dy, lessThan(0));
  });

  testWidgets('pressed: the highlight fades and the shadow pulls in and shrinks — a real sink, not a fade to nothing', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppPrimaryButton(label: 'Generate', icon: Icons.auto_awesome, onPressed: () {})),
    ));
    final restShadows = _decorationOf(tester).boxShadow!;

    final gesture = await tester.startGesture(tester.getCenter(find.byType(AppPrimaryButton)), kind: PointerDeviceKind.touch);
    await tester.pump(); // let the tap-down gesture actually resolve/dispatch first
    await tester.pump(const Duration(milliseconds: 120)); // full press-in duration
    final pressedShadows = _decorationOf(tester).boxShadow!;

    expect(pressedShadows[0].color.a, lessThan(restShadows[0].color.a), reason: 'highlight fades as it sinks');
    expect(pressedShadows[1].blurRadius, lessThan(restShadows[1].blurRadius), reason: 'ambient shadow shrinks, not just relocates');
    expect(pressedShadows[1].offset.dy, lessThan(restShadows[1].offset.dy), reason: 'shadow pulls in toward the surface');
    expect(pressedShadows[2].blurRadius, greaterThan(0), reason: 'still a real (smaller) shadow, not simply removed');

    await gesture.up();
    await tester.pump(); // let the tap-up gesture actually resolve/dispatch first
    await tester.pump(const Duration(milliseconds: 200)); // full release/spring-back duration
    final releasedShadows = _decorationOf(tester).boxShadow!;
    expect(releasedShadows[0].color.a, restShadows[0].color.a, reason: 'springs all the way back on release');
  });

  testWidgets('disabled (onPressed null): no shadow at all, and tapping does nothing', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppPrimaryButton(label: 'Generate', onPressed: null)),
    ));
    expect(_decorationOf(tester).boxShadow, isEmpty);
    await tester.tap(find.byType(AppPrimaryButton));
    expect(tapped, isFalse);
  });

  testWidgets('loading: shows a spinner instead of the icon, disables the button, and casts no shadow', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppPrimaryButton(label: 'Export', icon: Icons.description_outlined, loading: true, onPressed: () => tapped = true),
      ),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.description_outlined), findsNothing);
    expect(_decorationOf(tester).boxShadow, isEmpty);
    await tester.tap(find.byType(AppPrimaryButton));
    expect(tapped, isFalse, reason: 'a loading button must not be tappable');
  });

  testWidgets('a real tap fires onPressed', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppPrimaryButton(label: 'Submit', onPressed: () => tapped = true)),
    ));
    await tester.tap(find.byType(AppPrimaryButton));
    expect(tapped, isTrue);
  });

  testWidgets('expand: true (default) forces full available width', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppPrimaryButton(label: 'Export', onPressed: () {})),
    ));
    final container = tester.widget<Container>(find.byType(Container));
    expect(container.constraints?.maxWidth, double.infinity);
  });

  testWidgets('expand: false sizes to content instead of filling the width', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: AppPrimaryButton(label: 'Generate suggestions', onPressed: () {}, expand: false))),
    ));
    final container = tester.widget<Container>(find.byType(Container));
    expect(container.constraints, isNull, reason: 'no forced width — sizes to its own content');
  });

  testWidgets('label and icon are both shown', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppPrimaryButton(label: 'Approve & Sign', icon: Icons.verified_outlined, onPressed: () {})),
    ));
    expect(find.text('Approve & Sign'), findsOneWidget);
    expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
  });
}
