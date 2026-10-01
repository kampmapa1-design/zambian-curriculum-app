import 'package:flutter/material.dart';

import 'app_spacing.dart';

/// The app's single visual identity (Stage 8: UI/UX polish) — one seeded
/// [ColorScheme] plus a handful of component-level overrides, so every
/// screen picks up a consistent look automatically through Flutter's
/// theming rather than each screen hardcoding its own colors/spacing.
class AppTheme {
  AppTheme._();

  /// Deep blue — matches assets/icon/icon.png and the launcher icon
  /// background, so the in-app palette and the icon read as one identity.
  static const Color seed = Color(0xFF1565C0);
  static const Color accent = Color(0xFFF5A623);

  /// Real bug found and fixed here (Stage N of the aesthetics pass,
  /// 2026-09-27, via a genuine WCAG contrast test — see
  /// test/dark_theme_test.dart): overriding `secondary: accent` without
  /// also overriding `onSecondary` left Flutter's own seed-algorithm
  /// picking white text for it in light mode — 2.03:1 against this accent,
  /// nowhere near WCAG AA's 4.5:1. `accent` is a mid-luminance gold, and
  /// [ThemeData.estimateBrightnessForColor] correctly says it needs DARK
  /// text (10.4:1 against black) — computed once, explicitly, rather than
  /// left to a per-brightness heuristic that happened to get dark mode
  /// right and light mode wrong for the exact same color.
  static Color get _onAccent =>
      ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      secondary: accent,
      onSecondary: _onAccent,
      brightness: Brightness.light,
    );
    return _themeFrom(colorScheme);
  }

  static ThemeData dark() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      secondary: accent,
      onSecondary: _onAccent,
      brightness: Brightness.dark,
    );
    return _themeFrom(colorScheme);
  }

  static ThemeData _themeFrom(ColorScheme colorScheme) {
    final base = ThemeData(colorScheme: colorScheme, useMaterial3: true);
    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        elevation: AppElevation.card,
        margin: EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ),
      // Stage G (elevation/depth token system, 2026-09-27): dialogs and
      // bottom sheets are the highest tier on the new scale — see
      // AppElevation's own doc comment for why (paired with a blurred
      // backdrop in Stage J). FABs and popup menus/tooltips get their own
      // named tiers rather than Flutter's mismatched built-in defaults, so
      // the whole app now reads off ONE consistent depth scale.
      dialogTheme: const DialogThemeData(elevation: AppElevation.overlay),
      bottomSheetTheme: const BottomSheetThemeData(
        elevation: AppElevation.overlay,
        modalElevation: AppElevation.overlay,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      ),
      popupMenuTheme: const PopupMenuThemeData(elevation: AppElevation.overlay),
      snackBarTheme: const SnackBarThemeData(elevation: AppElevation.floating),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: const StadiumBorder(),
        selectedColor: colorScheme.primaryContainer,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.secondary,
        foregroundColor: colorScheme.onSecondary,
        elevation: AppElevation.floating,
        highlightElevation: AppElevation.overlay,
      ),
      dividerTheme: DividerThemeData(color: colorScheme.outlineVariant, space: 32),
      textTheme: _textTheme(base.textTheme),
    );
  }

  /// Lexend for anything display/headline/title-tier (the "voice" of the
  /// app — screen titles, section headers, empty-state headlines), Inter
  /// for everything else (body copy, dense forms/tables, labels) — picked
  /// deliberately, not just "a nicer default than Roboto": Lexend was
  /// designed with reading-proficiency research behind it, a fitting
  /// pairing for an education app, while Inter is built for exactly the
  /// long-form/data-dense reading this app does a lot of (marking review,
  /// report forms, scheme-of-work tables).
  static TextTheme _textTheme(TextTheme base) {
    final body = base.apply(fontFamily: 'Inter');
    TextStyle? lexend(TextStyle? style, FontWeight weight) =>
        style?.copyWith(fontFamily: 'Lexend', fontWeight: weight);
    return body.copyWith(
      displayLarge: lexend(body.displayLarge, FontWeight.w700),
      displayMedium: lexend(body.displayMedium, FontWeight.w700),
      displaySmall: lexend(body.displaySmall, FontWeight.w600),
      headlineLarge: lexend(body.headlineLarge, FontWeight.w700),
      headlineMedium: lexend(body.headlineMedium, FontWeight.w600),
      headlineSmall: lexend(body.headlineSmall, FontWeight.w600),
      titleLarge: lexend(body.titleLarge, FontWeight.w600),
      titleMedium: lexend(body.titleMedium, FontWeight.w600),
      titleSmall: lexend(body.titleSmall, FontWeight.w600),
      labelLarge: body.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}
