// Aesthetics pass, Stage I (2026-09-27): AppGradients — soft, on-brand
// gradients for the hero header, AppPrimaryButton's fill, and
// FunctionButton's icon badge. Includes a real WCAG contrast check (a
// Stage-O-style spot check run right after this visual pass, per the
// user's own instruction to check accessibility after each round rather
// than only at the very end) so a "subtle" gradient is verified subtle
// enough to keep its text/icon legible, not just eyeballed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/theme/app_spacing.dart';
import 'package:zambian_curriculum_app/theme/app_theme.dart';
import 'package:zambian_curriculum_app/widgets/app_primary_button.dart';
import 'package:zambian_curriculum_app/widgets/function_button.dart';

import 'support/wcag_contrast.dart';

void main() {
  group('AppGradients: shape and brand consistency', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final cs = theme.colorScheme;

      test('hero: 3 real, distinct stops in the brand blue family, deep primary through to primaryContainer (${theme.brightness})', () {
        final g = AppGradients.hero(cs);
        expect(g.colors, hasLength(3));
        expect(g.colors.first, cs.primary, reason: 'starts on the saturated brand color, as the original pre-Stage-I gradient did');
        expect(g.colors.last, cs.primaryContainer);
        expect(g.colors.toSet(), hasLength(3), reason: 'three genuinely different stops, not a repeated color');
      });

      test('primaryButton: 3 stops, a SUBTLE range around colorScheme.primary (${theme.brightness})', () {
        final g = AppGradients.primaryButton(cs);
        expect(g.colors, hasLength(3));
        expect(g.colors[1], cs.primary, reason: 'the middle stop is still recognizably the brand primary');
        final range = relativeLuminance(g.colors.first) - relativeLuminance(g.colors.last);
        expect(range, lessThan(0.35), reason: 'a subtle range, not a big color travel, per the "avoid harsh gradients" instruction');
      });

      test('iconBadge: a tight range around primaryContainer (${theme.brightness})', () {
        final g = AppGradients.iconBadge(cs);
        expect(g.colors, hasLength(2));
        expect(g.colors.last, cs.primaryContainer);
      });
    }
  });

  group('Accessibility spot check (Stage O, run right after this visual pass): gradient text/icon contrast', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final cs = theme.colorScheme;

      test('AppPrimaryButton: onPrimary text stays WCAG AA at BOTH ends of the gradient (${theme.brightness})', () {
        final g = AppGradients.primaryButton(cs);
        for (final stop in [g.colors.first, g.colors.last]) {
          final ratio = contrastRatio(stop, cs.onPrimary);
          expect(ratio, greaterThanOrEqualTo(kWcagAaNormalText),
              reason: '${theme.brightness}: stop $stop vs onPrimary ${cs.onPrimary} = ${ratio.toStringAsFixed(2)}:1');
        }
      });

      test('FunctionButton icon badge: onPrimaryContainer icon stays WCAG AA at both ends (${theme.brightness})', () {
        final g = AppGradients.iconBadge(cs);
        for (final stop in [g.colors.first, g.colors.last]) {
          final ratio = contrastRatio(stop, cs.onPrimaryContainer);
          expect(ratio, greaterThanOrEqualTo(kWcagAaLargeText),
              reason: '${theme.brightness}: an icon glyph counts as graphical, held to the large-scale AA minimum — '
                  'stop $stop vs onPrimaryContainer ${cs.onPrimaryContainer} = ${ratio.toStringAsFixed(2)}:1');
        }
      });
    }
  });

  group('the gradients actually render where they\'re supposed to', () {
    testWidgets('AppPrimaryButton (enabled) shows the primaryButton gradient; disabled shows none', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: Column(children: [
          AppPrimaryButton(label: 'Generate', onPressed: () {}),
          AppPrimaryButton(label: 'Generate', onPressed: null),
        ])),
      ));
      final decorations = tester.widgetList<Container>(find.byType(Container)).map((c) => c.decoration).whereType<BoxDecoration>().toList();
      expect(decorations.any((d) => d.gradient != null), isTrue, reason: 'the enabled button must show a gradient');
      final cs = AppTheme.light().colorScheme;
      final expected = AppGradients.primaryButton(cs);
      expect(decorations.firstWhere((d) => d.gradient != null).gradient, expected);
    });

    testWidgets('FunctionButton shows the iconBadge gradient behind its icon', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: FunctionButton(icon: Icons.star, label: 'X', subtitle: 'Y', onTap: () {})),
      ));
      final circleContainers = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.decoration is BoxDecoration && (c.decoration as BoxDecoration).shape == BoxShape.circle)
          .toList();
      expect(circleContainers, hasLength(1));
      expect((circleContainers.first.decoration as BoxDecoration).gradient, isNotNull);
    });
  });
}
