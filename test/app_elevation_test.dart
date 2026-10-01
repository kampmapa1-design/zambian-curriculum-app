// Aesthetics pass, Stage G (2026-09-27): the elevation/depth token system —
// AppElevation's own 6-level scale and custom two-layer shadow generator,
// AppTheme wiring every elevation-consuming Material component to it, and
// FunctionButton (the app's most-repeated "pick a function" surface) using
// the real custom shadow instead of Card's built-in single shadow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/theme/app_spacing.dart';
import 'package:zambian_curriculum_app/theme/app_theme.dart';
import 'package:zambian_curriculum_app/widgets/function_button.dart';

void main() {
  group('AppElevation scale', () {
    test('six named levels, strictly increasing, matching the spec\'s ordering', () {
      const levels = [
        AppElevation.flat,
        AppElevation.card,
        AppElevation.raised,
        AppElevation.selected,
        AppElevation.floating,
        AppElevation.overlay,
      ];
      expect(levels, hasLength(6));
      for (var i = 1; i < levels.length; i++) {
        expect(levels[i], greaterThan(levels[i - 1]), reason: 'level $i must sit higher than level ${i - 1}');
      }
    });

    test('flat has no shadow at all', () {
      expect(AppElevation.shadowsFor(AppElevation.flat), isEmpty);
    });

    test('every non-flat level is a real two-layer shadow with a deliberate (non-zero) spread', () {
      for (final level in [AppElevation.card, AppElevation.raised, AppElevation.selected, AppElevation.floating, AppElevation.overlay]) {
        final shadows = AppElevation.shadowsFor(level);
        expect(shadows, hasLength(2), reason: 'level $level');
        final ambient = shadows[0];
        final contact = shadows[1];
        expect(ambient.blurRadius, greaterThan(0));
        expect(ambient.offset.dy, greaterThan(0));
        expect(contact.spreadRadius, isNot(0), reason: 'a deliberate spread value, not left at the Flutter default of 0');
        expect(contact.spreadRadius, lessThan(0), reason: 'a slightly negative spread keeps the contact shadow from bleeding past the edge');
      }
    });

    test('higher levels cast a bigger, more visible shadow than lower ones', () {
      final card = AppElevation.shadowsFor(AppElevation.card);
      final overlay = AppElevation.shadowsFor(AppElevation.overlay);
      expect(overlay[0].blurRadius, greaterThan(card[0].blurRadius), reason: 'ambient blur grows with elevation');
      expect(overlay[0].offset.dy, greaterThan(card[0].offset.dy), reason: 'ambient offset grows with elevation');
      expect(_alphaOf(overlay[1].color), greaterThan(_alphaOf(card[1].color)), reason: 'contact shadow opacity grows with elevation');
    });

    test('dark surfaces get a different (not just copy-pasted) shadow than light ones', () {
      const level = AppElevation.card;
      final light = AppElevation.shadowsFor(level);
      final dark = AppElevation.shadowsFor(level, brightness: Brightness.dark);
      expect(_alphaOf(dark[0].color), isNot(_alphaOf(light[0].color)));
      expect(_alphaOf(dark[1].color), isNot(_alphaOf(light[1].color)));
    });
  });

  group('AppTheme: every elevation-consuming component follows the token scale', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      test('cardTheme / dialogTheme / bottomSheetTheme / FAB / popupMenu / snackBar (${theme.brightness})', () {
        expect(theme.cardTheme.elevation, AppElevation.card);
        expect(theme.dialogTheme.elevation, AppElevation.overlay);
        expect(theme.bottomSheetTheme.elevation, AppElevation.overlay);
        expect(theme.bottomSheetTheme.modalElevation, AppElevation.overlay);
        expect(theme.floatingActionButtonTheme.elevation, AppElevation.floating);
        expect(theme.floatingActionButtonTheme.highlightElevation, AppElevation.overlay);
        expect(theme.popupMenuTheme.elevation, AppElevation.overlay);
        expect(theme.snackBarTheme.elevation, AppElevation.floating);
        // Modals/sheets are the highest tier, strictly above a resting card
        // and above a FAB — exactly the ordering Stage G asked for.
        expect(theme.dialogTheme.elevation, greaterThan(theme.floatingActionButtonTheme.elevation!));
        expect(theme.floatingActionButtonTheme.elevation, greaterThan(theme.cardTheme.elevation!));
      });
    }
  });

  group('FunctionButton uses the real custom shadow, not Card\'s built-in one', () {
    testWidgets('a Container carries the two-layer shadow; the inner Card contributes none of its own', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: FunctionButton(icon: Icons.star, label: 'Test', subtitle: 'Subtitle', onTap: () {}),
        ),
      ));

      final card = tester.widget<Card>(find.byType(Card));
      expect(card.elevation, 0, reason: 'the Card itself must not add Material\'s own single shadow on top');

      final containers = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.decoration is BoxDecoration && (c.decoration as BoxDecoration).boxShadow != null)
          .toList();
      expect(containers, isNotEmpty, reason: 'no Container in the tree carries the custom shadow');
      final shadow = (containers.first.decoration as BoxDecoration).boxShadow!;
      expect(shadow, AppElevation.shadowsFor(AppElevation.card, brightness: Brightness.light));
    });

    testWidgets('still tappable and shows its label/subtitle', (tester) async {
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FunctionButton(icon: Icons.star, label: 'Generate', subtitle: 'Make one', onTap: () => tapped = true),
        ),
      ));
      expect(find.text('Generate'), findsOneWidget);
      expect(find.text('Make one'), findsOneWidget);
      await tester.tap(find.byType(InkWell).first);
      // Stage M (micro-interactions): onTap now fires after a brief
      // lift-and-settle animation, not synchronously on tap — see
      // test/app_micro_interactions_test.dart for that behavior itself.
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });
}

double _alphaOf(Color c) => c.a;
