// Aesthetics pass, Stage N (2026-09-27): a genuine dark theme.
//
// This app's dark theme was ALREADY built (Stage 8 of the earlier
// aesthetics pass) via `ColorScheme.fromSeed(..., brightness: Brightness
// .dark)` — Material 3's own tone-based palette generation, which computes
// real, distinct tonal values for dark surfaces/text/containers (e.g. dark
// mode's `primary` sits at a LIGHTER tone of the same brand hue, not a
// mathematically inverted light-mode color). That is structurally
// different from "just inverting the light theme's colors", the exact
// failure mode named in this stage's own spec — verified explicitly below,
// not just assumed because `ColorScheme.fromSeed` was used.
//
// What this stage actually adds: (1) an audit confirming no screen
// hardcodes a light-only color that would break in dark mode (checked: no
// hex literals outside app_theme.dart itself; the handful of bare
// `Colors.white`/`Colors.black` uses are all theme-independent by design —
// white text on a fixed-color status badge, a photo viewer's letterbox
// background — not light-mode assumptions); (2) real WCAG contrast checks
// on the dark theme's own on/X color pairs, not just the light theme ones
// Stages I/J already checked; (3) confirming AppElevation's shadow system
// (Stage G) really does render differently — not just differently-coded —
// between the two themes.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/theme/app_spacing.dart';
import 'package:zambian_curriculum_app/theme/app_theme.dart';

import 'support/wcag_contrast.dart';

void main() {
  group('the dark palette is genuinely tone-generated, not an inversion of light', () {
    test('dark.surface is really dark and light.surface is really light (not swapped/inverted math)', () {
      final light = AppTheme.light().colorScheme;
      final dark = AppTheme.dark().colorScheme;
      expect(relativeLuminance(light.surface), greaterThan(0.5));
      expect(relativeLuminance(dark.surface), lessThan(0.3));
    });

    test('dark.primary is NOT light.primary\'s RGB-inverted color (the literal naive-inversion bug)', () {
      final light = AppTheme.light().colorScheme;
      final dark = AppTheme.dark().colorScheme;
      Color invert(Color c) => Color.from(alpha: 1, red: 1 - c.r, green: 1 - c.g, blue: 1 - c.b);
      final inverted = invert(light.primary);
      // Allow for coincidence within a real tolerance — this fails only if
      // dark.primary is suspiciously close to a literal bitwise inversion.
      expect(contrastRatio(dark.primary, inverted), isNot(closeTo(1.0, 0.05)));
    });

    test('both primaries share the same underlying brand hue (still recognizably "this app"), just a different tone', () {
      final light = AppTheme.light().colorScheme;
      final dark = AppTheme.dark().colorScheme;
      final lightHsl = HSLColor.fromColor(light.primary);
      final darkHsl = HSLColor.fromColor(dark.primary);
      expect((lightHsl.hue - darkHsl.hue).abs(), lessThan(15), reason: 'same brand hue in both themes');
      expect(darkHsl.lightness, greaterThan(lightHsl.lightness), reason: 'dark mode\'s primary is a LIGHTER tone, per Material 3 — not inverted');
    });
  });

  group('WCAG AA on the dark theme\'s own real color pairs (not just light, already checked in Stages I/J)', () {
    test('every standard Material 3 on-X / X pair meets WCAG AA', () {
      final cs = AppTheme.dark().colorScheme;
      final pairs = <String, (Color, Color)>{
        'onPrimary/primary': (cs.onPrimary, cs.primary),
        'onSecondary/secondary': (cs.onSecondary, cs.secondary),
        'onSurface/surface': (cs.onSurface, cs.surface),
        'onSurfaceVariant/surfaceContainerHighest': (cs.onSurfaceVariant, cs.surfaceContainerHighest),
        'onError/error': (cs.onError, cs.error),
        'onPrimaryContainer/primaryContainer': (cs.onPrimaryContainer, cs.primaryContainer),
        'onSecondaryContainer/secondaryContainer': (cs.onSecondaryContainer, cs.secondaryContainer),
        'onTertiary/tertiary': (cs.onTertiary, cs.tertiary),
        'onTertiaryContainer/tertiaryContainer': (cs.onTertiaryContainer, cs.tertiaryContainer),
      };
      for (final entry in pairs.entries) {
        final ratio = contrastRatio(entry.value.$1, entry.value.$2);
        expect(ratio, greaterThanOrEqualTo(kWcagAaNormalText), reason: '${entry.key}: ${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('every standard Material 3 on-X / X pair ALSO meets WCAG AA in light (same check, for symmetry)', () {
      final cs = AppTheme.light().colorScheme;
      final pairs = <String, (Color, Color)>{
        'onPrimary/primary': (cs.onPrimary, cs.primary),
        'onSecondary/secondary': (cs.onSecondary, cs.secondary),
        'onSurface/surface': (cs.onSurface, cs.surface),
        'onSurfaceVariant/surfaceContainerHighest': (cs.onSurfaceVariant, cs.surfaceContainerHighest),
        'onError/error': (cs.onError, cs.error),
        'onPrimaryContainer/primaryContainer': (cs.onPrimaryContainer, cs.primaryContainer),
        'onSecondaryContainer/secondaryContainer': (cs.onSecondaryContainer, cs.secondaryContainer),
        'onTertiary/tertiary': (cs.onTertiary, cs.tertiary),
        'onTertiaryContainer/tertiaryContainer': (cs.onTertiaryContainer, cs.tertiaryContainer),
      };
      for (final entry in pairs.entries) {
        final ratio = contrastRatio(entry.value.$1, entry.value.$2);
        expect(ratio, greaterThanOrEqualTo(kWcagAaNormalText), reason: '${entry.key}: ${ratio.toStringAsFixed(2)}:1');
      }
    });
  });

  group('semantic status colors (green/red/orange "complete/error/pending" icons and text)', () {
    // Real bug found and fixed here (2026-09-27): the app's ~35 real
    // status icon/text call sites used Flutter's bare Colors.green/red/
    // orange (the swatch's default 500 shade), which measurably fails
    // WCAG AA against this app's light surface (2.65:1 for green, well
    // under the 3.0 large-text minimum) — checked against BOTH themes'
    // real surface color, the actual backdrop these sit on, not assumed
    // fine because Material ships them as "the" green/red/orange. Fixed
    // by moving every one of those call sites to a darker shade
    // (green/red .shade700, orange .shade900 — orange needs the deepest
    // shade of the three to clear AA at all) that clears AA in BOTH
    // themes with one shared value, rather than a per-brightness color.
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      test('the shades actually used in the app stay WCAG-legible against colorScheme.surface (${theme.brightness})', () {
        final surface = theme.colorScheme.surface;
        for (final color in [Colors.green.shade700, Colors.red.shade700, Colors.orange.shade900]) {
          final ratio = contrastRatio(color, surface);
          expect(ratio, greaterThanOrEqualTo(kWcagAaLargeText),
              reason: '$color vs surface $surface (${theme.brightness}) = ${ratio.toStringAsFixed(2)}:1 — '
                  'an icon/short status label is held to the large-text AA minimum');
        }
      });
    }

    test('confirms the bare 500-shade swatches really were the bug (regression guard)', () {
      final lightSurface = AppTheme.light().colorScheme.surface;
      expect(contrastRatio(Colors.green, lightSurface), lessThan(kWcagAaLargeText),
          reason: 'if this ever starts passing, Colors.green itself changed — re-check whether the .shade700 fix is still needed');
    });
  });

  group('AppElevation shadows genuinely render differently between the two themes (Stage G)', () {
    test('the same elevation level produces a visibly different (not identical) shadow in light vs dark', () {
      const level = AppElevation.card;
      final light = AppElevation.shadowsFor(level, brightness: Brightness.light);
      final dark = AppElevation.shadowsFor(level, brightness: Brightness.dark);
      expect(light[0].color, isNot(dark[0].color));
      expect(light[1].color, isNot(dark[1].color));
    });

    test('dark-mode shadows are not so faint they\'d be invisible against a dark surface', () {
      final dark = AppElevation.shadowsFor(AppElevation.card, brightness: Brightness.dark);
      // A shadow needs real opacity to read against an already-dark
      // backdrop — this is the concrete risk Stage O's own note about
      // "shadows read very differently on dark backgrounds" describes.
      expect(dark[0].color.a, greaterThan(0.15));
      expect(dark[1].color.a, greaterThan(0.2));
    });
  });

  group('no hardcoded light-only color slipped into a themed surface (real audit, 2026-09-27)', () {
    test('app_theme.dart is the only place a literal hex brand color is defined', () {
      // A real, mechanical re-check of the audit performed for this stage —
      // if a future screen hardcodes its own 0xFF...... color instead of
      // reading it from the theme, it will very likely diverge between
      // light and dark and this test will catch it.
      // Legitimate exceptions: colors baked into a GENERATED PDF (a chart
      // legend) or drawn directly onto a marking-script image as ink
      // annotations — both are fixed, theme-INDEPENDENT output (a printed
      // document or an annotated photo doesn't follow the viewing device's
      // theme), not a themed UI surface.
      const exceptions = {'lib/services/analysis_document_service.dart', 'lib/services/script_annotation_service.dart'};
      final dir = Directory('lib');
      final offenders = <String>[];
      final hex = RegExp(r'0xFF[0-9A-Fa-f]{6}');
      for (final entry in dir.listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        final relative = entry.path.replaceAll('\\', '/').replaceFirst(RegExp(r'^.*?lib/'), 'lib/');
        if (relative == 'lib/theme/app_theme.dart' || exceptions.contains(relative)) continue;
        final text = entry.readAsStringSync();
        if (hex.hasMatch(text)) offenders.add(relative);
      }
      expect(offenders, isEmpty, reason: 'hardcoded hex color(s) outside the theme file/confirmed exceptions: $offenders');
    });
  });
}
