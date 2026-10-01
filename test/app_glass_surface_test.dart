// Aesthetics pass, Stage J (2026-09-27): AppGlassSurface (frosted-glass
// overlays) — the real ad-gate dialog (showOutOfCreditsDialog), the
// batch-marking confirmation leading into the batch review flow, and a
// real bottom sheet, all converted to it. Includes a real WCAG contrast
// check against BOTH a worst-case black and white backdrop — glassmorphism's
// actual accessibility risk is an unpredictable background reducing
// contrast, so the tint alpha is verified against both extremes, not
// assumed safe.
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/theme/app_theme.dart';
import 'package:zambian_curriculum_app/widgets/app_glass_surface.dart';

import 'support/wcag_contrast.dart';

Color _blendOverBackdrop(Color foreground, Color backdrop) {
  // Standard "over" alpha compositing — what a viewer actually sees when a
  // translucent foreground sits on top of an opaque backdrop.
  final a = foreground.a;
  double mix(double f, double b) => f * a + b * (1 - a);
  return Color.from(alpha: 1, red: mix(foreground.r, backdrop.r), green: mix(foreground.g, backdrop.g), blue: mix(foreground.b, backdrop.b));
}

void main() {
  group('AppGlassSurface: real rendering', () {
    testWidgets('blurs, tints and borders its content — genuinely different from a plain flat Container', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: Center(child: AppGlassSurface(child: Text('Content')))),
      ));
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text('Content'), findsOneWidget);
      final container = tester.widget<Container>(
        find.descendant(of: find.byType(BackdropFilter), matching: find.byType(Container)).first,
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color!.a, lessThan(1.0), reason: 'translucent, not opaque');
      expect(decoration.border, isNotNull, reason: 'a subtle border, per the spec');
    });
  });

  group('Accessibility spot check (Stage O-lite, run right after this visual pass): glass tint vs worst-case backdrops', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      test('body text (onSurface) stays WCAG AA over BOTH a pure-white and pure-black backdrop (${theme.brightness})', () {
        final cs = theme.colorScheme;
        final tint = cs.surface.withValues(alpha: AppGlassSurface.tintAlpha(theme.brightness));
        for (final backdrop in [Colors.white, Colors.black]) {
          final rendered = _blendOverBackdrop(tint, backdrop);
          final ratio = contrastRatio(rendered, cs.onSurface);
          expect(ratio, greaterThanOrEqualTo(kWcagAaNormalText),
              reason: '${theme.brightness} over $backdrop backdrop: rendered=$rendered onSurface=${cs.onSurface} = ${ratio.toStringAsFixed(2)}:1');
        }
      });
    }
  });

  group('showAppGlassAlertDialog: the real ad-gate + batch-marking dialogs\' shape', () {
    testWidgets('shows title/content/actions on the glass surface, and returns the tapped action\'s value', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: SizedBox())));
      final context = tester.element(find.byType(Scaffold));

      String? result;
      unawaited(showAppGlassAlertDialog<String>(
        context,
        title: 'Out of credits',
        content: const Text('You do not have enough credits.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop('not now'), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.of(context).pop('get credits'), child: const Text('Get credits')),
        ],
      ).then((v) => result = v));
      await tester.pumpAndSettle();

      expect(find.text('Out of credits'), findsOneWidget);
      expect(find.text('You do not have enough credits.'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsWidgets, reason: 'both the barrier blur and the surface blur');

      await tester.tap(find.text('Get credits'));
      await tester.pumpAndSettle();
      expect(result, 'get credits');
    });

    testWidgets('barrierDismissible: false cannot be tapped away', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: SizedBox())));
      final context = tester.element(find.byType(Scaffold));

      unawaited(showAppGlassAlertDialog<void>(
        context,
        title: 'Blocking',
        content: const Text('Must choose'),
        actions: const [],
        barrierDismissible: false,
      ));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Blocking'), findsOneWidget);
    });
  });

  group('showAppGlassBottomSheet: a real picker sheet', () {
    testWidgets('shows its content on the glass surface and returns the tapped option', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: SizedBox())));
      final context = tester.element(find.byType(Scaffold));

      String? picked;
      unawaited(showAppGlassBottomSheet<String>(
        context,
        builder: (sheetContext) => Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: const Text('Scan with Camera'), onTap: () => Navigator.of(sheetContext).pop('camera')),
          ListTile(title: const Text('Upload from Device'), onTap: () => Navigator.of(sheetContext).pop('device')),
        ]),
      ).then((v) => picked = v));
      await tester.pumpAndSettle();

      expect(find.text('Scan with Camera'), findsOneWidget);
      await tester.tap(find.text('Upload from Device'));
      await tester.pumpAndSettle();
      expect(picked, 'device');
    });
  });
}
