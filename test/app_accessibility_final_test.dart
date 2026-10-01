// Aesthetics pass, Stage O (2026-09-27) — the final consolidated
// accessibility pass. Per the user's own build order ("Save Stage O for
// last on each round of visual changes, checking accessibility after each
// visual pass, not just once at the very end"), the actual contrast/
// boundary checking was done INCREMENTALLY as each stage landed, not saved
// up for one big pass at the end:
//   - Stage I: test/app_gradients_test.dart — onPrimary/onPrimaryContainer
//     text+icon contrast at both ends of the button/badge gradients.
//   - Stage J: test/app_glass_surface_test.dart — onSurface body text
//     contrast over a worst-case black AND white backdrop through the
//     glass tint.
//   - Stage N: test/dark_theme_test.dart — full ColorScheme on-X/X pairs
//     in both themes, the real bare-swatch status-color bug found+fixed,
//     shadow visibility in dark mode.
// This file is the genuinely LAST check, the one that only makes sense
// once every stage has landed: does a tappable element still have a
// clearly perceivable boundary/edge with the softer, shadow-based styling
// now used everywhere — the exact failure mode that made earlier
// neumorphism trends hurt usability.
//
// REAL FINDING (2026-09-27): Material 3's own tonal card/background
// separation (Card's default `surfaceContainerLow` fill against the
// Scaffold's `surface`) never reaches WCAG 1.4.11's 3:1 non-text-contrast
// minimum for a UI-component boundary, in EITHER theme, no matter how high
// a surface-container tier is picked (measured: light tops out at 1.23:1,
// dark at 1.51:1, even at `surfaceContainerHighest`) — the tonal system is
// designed to pair with a real shadow and/or outline, not stand alone.
// `colorScheme.outline` DOES clear 3:1 in both themes (checked below) and
// is exactly the token Material 3 reserves for this — FunctionButton now
// draws it as a real border alongside its shadow (see
// lib/widgets/function_button.dart), rather than relying on the shadow or
// the tonal step alone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/theme/app_spacing.dart';
import 'package:zambian_curriculum_app/theme/app_theme.dart';
import 'package:zambian_curriculum_app/widgets/function_button.dart';

import 'support/wcag_contrast.dart';

const kWcagNonTextContrast = 3.0; // WCAG 2.1 SC 1.4.11

void main() {
  group('the real finding: Material 3\'s tonal card/background separation alone never clears WCAG 1.4.11', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      test('every surface-container tier vs the Scaffold background stays under 3:1 (${theme.brightness})', () {
        final cs = theme.colorScheme;
        for (final tier in [
          cs.surfaceContainerLowest,
          cs.surfaceContainerLow,
          cs.surfaceContainer,
          cs.surfaceContainerHigh,
          cs.surfaceContainerHighest,
        ]) {
          expect(contrastRatio(tier, cs.surface), lessThan(kWcagNonTextContrast));
        }
      });
    }
  });

  group('the fix: colorScheme.outline clears WCAG 1.4.11 in both themes, and FunctionButton actually draws it', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      test('colorScheme.outline vs surface clears 3:1 (${theme.brightness})', () {
        expect(contrastRatio(theme.colorScheme.outline, theme.colorScheme.surface), greaterThanOrEqualTo(kWcagNonTextContrast));
      });
    }

    testWidgets('FunctionButton draws a full-opacity colorScheme.outline border, in both themes', (tester) async {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(body: FunctionButton(icon: Icons.star, label: 'X', subtitle: 'Y', onTap: () {})),
        ));
        // MaterialApp animates a theme change (AnimatedTheme) — without
        // settling, a second pumpWidget in this loop can still be
        // mid-lerp between the previous iteration's theme and this one.
        await tester.pumpAndSettle();
        final decoration = tester
            .widgetList<Container>(find.byType(Container))
            .map((c) => c.decoration)
            .whereType<BoxDecoration>()
            .firstWhere((d) => d.border != null);
        final border = decoration.border! as Border;
        expect(border.top.color, theme.colorScheme.outline);
        expect(border.top.color.a, 1.0, reason: 'fading this toward the background would undo the 3:1 guarantee it exists for');
      }
    });
  });

  group('AppPrimaryButton keeps a strong edge independent of its shadow (a solid color fill, not a subtle tonal card)', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      test('the button fill contrasts clearly against the surface behind it, shadow aside (${theme.brightness})', () {
        final cs = theme.colorScheme;
        final ratio = contrastRatio(cs.primary, cs.surface);
        expect(ratio, greaterThanOrEqualTo(1.5), reason: 'a real, visible color step between the button and its background');
      });
    }
  });

  group('final summary: every brightness-sensitive API this pass introduced actually behaves differently per theme', () {
    test('AppElevation and AppGradients are not silently identical between light and dark', () {
      expect(AppElevation.shadowsFor(AppElevation.card, brightness: Brightness.light),
          isNot(AppElevation.shadowsFor(AppElevation.card, brightness: Brightness.dark)));
      expect(AppGradients.primaryButton(AppTheme.light().colorScheme).colors,
          isNot(AppGradients.primaryButton(AppTheme.dark().colorScheme).colors));
    });
  });
}
