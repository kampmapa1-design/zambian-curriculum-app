// Aesthetics pass, Stage M (2026-09-27): purposeful micro-interactions —
// FunctionButton's card-lift-on-tap, SuccessCheckmark, and
// AppAnimatedLinearProgress's gentle fill. Each is tied to a real state
// change (about to navigate; a batch finishing; a progress value
// changing), never decorative motion for its own sake, and kept under the
// spec's own ~300ms-per-animation ceiling.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/widgets/app_animated_progress.dart';
import 'package:zambian_curriculum_app/widgets/function_button.dart';
import 'package:zambian_curriculum_app/widgets/success_checkmark.dart';

void main() {
  group('FunctionButton: card-lift-on-tap before navigation', () {
    testWidgets('lifts (translates up, shadow deepens) during the brief pause, then calls onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FunctionButton(icon: Icons.star, label: 'Generate', subtitle: 'X', onTap: () => tapped = true)),
      ));

      Matrix4 liftTransform() => tester
          .widget<Transform>(find.descendant(of: find.byType(FunctionButton), matching: find.byType(Transform)).first)
          .transform;

      expect(liftTransform().getTranslation().y, 0, reason: 'flush with the surface at rest');

      await tester.tap(find.byType(FunctionButton));
      await tester.pump(); // let the tap actually resolve/dispatch first
      await tester.pump(const Duration(milliseconds: 55)); // partway through the lift
      expect(liftTransform().getTranslation().y, lessThan(0), reason: 'lifted upward mid-animation');
      expect(tapped, isFalse, reason: 'onTap must not fire until the lift-and-settle finishes');

      await tester.pumpAndSettle();
      expect(tapped, isTrue, reason: 'onTap fires once the animation completes');
      expect(liftTransform().getTranslation().y, 0, reason: 'settles back down after the lift');
    });

    testWidgets('the whole lift-then-tap sequence stays well under a second (brief, per the spec)', (tester) async {
      final stopwatch = Stopwatch()..start();
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FunctionButton(icon: Icons.star, label: 'X', subtitle: 'Y', onTap: () => tapped = true)),
      ));
      await tester.tap(find.byType(FunctionButton));
      await tester.pumpAndSettle();
      stopwatch.stop();
      expect(tapped, isTrue);
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });
  });

  group('SuccessCheckmark', () {
    testWidgets('pops in with a scale animation, ending at full size', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SuccessCheckmark())));
      double scaleOf() => tester
          .widget<ScaleTransition>(find.descendant(of: find.byType(SuccessCheckmark), matching: find.byType(ScaleTransition)).first)
          .scale
          .value;
      final early = scaleOf();
      await tester.pump(const Duration(milliseconds: 260));
      final settled = scaleOf();
      expect(settled, closeTo(1.0, 0.01));
      expect(early, isNot(closeTo(1.0, 0.01)), reason: 'starts small/zero, not already full size');
      expect(find.byIcon(Icons.check_outlined), findsOneWidget);
    });
  });

  group('AppAnimatedLinearProgress: gentle fill, not an instant jump', () {
    testWidgets('a value change animates smoothly toward the new target rather than snapping', (tester) async {
      double value = 0.2;
      late StateSetter setSheetState;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setSheetState = setState;
              return AppAnimatedLinearProgress(value: value);
            },
          ),
        ),
      ));
      LinearProgressIndicator bar() => tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      await tester.pumpAndSettle(); // let the very first mount's own build->target animation finish
      expect(bar().value, closeTo(0.2, 0.01));

      setSheetState(() => value = 0.8);
      await tester.pump(const Duration(milliseconds: 300)); // rebuild with the new target
      await tester.pump(const Duration(milliseconds: 50)); // partway through the animated fill
      final mid = bar().value!;
      expect(mid, greaterThan(0.2), reason: 'moving toward the new value');
      expect(mid, lessThan(0.8), reason: 'not an instant jump straight to the new value');

      await tester.pumpAndSettle();
      expect(bar().value, closeTo(0.8, 0.01), reason: 'reaches the real target once settled');
    });

    testWidgets('null value stays a real indeterminate bar', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AppAnimatedLinearProgress(value: null))));
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, isNull);
    });

    testWidgets('out-of-range values are clamped, not passed straight to Flutter\'s own indicator', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AppAnimatedLinearProgress(value: 1.4))));
      await tester.pumpAndSettle();
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(1.0, 0.01));
    });
  });
}
