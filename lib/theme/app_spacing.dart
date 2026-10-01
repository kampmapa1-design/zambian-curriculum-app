import 'package:flutter/material.dart';

/// Design tokens (Stage B of the aesthetics pass) — a single source of
/// truth for spacing, so screens stop hardcoding their own scattered
/// `EdgeInsets.all(16)`/`SizedBox(height: 12)` values ad hoc. An 8px base
/// scale (the standard Material spacing rhythm) — every value is a
/// multiple of 8 (4 as the one deliberate half-step, for tight inline gaps
/// like an icon-to-label gap) so spacing composes cleanly instead of
/// producing off-rhythm gaps when two tokens sit next to each other.
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// Corner-radius scale — matches what [AppTheme] already applies to cards
/// (12) and buttons (10); this is the token version of those same numbers
/// plus a couple more sizes, so a screen reaching for "the card radius"
/// gets the actual shared value instead of guessing/retyping `12`.
class AppRadius {
  AppRadius._();

  static const double sm = 8;
  static const double button = 10;
  static const double md = 12;
  static const double lg = 16;

  static const BorderRadius smRadius = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius buttonRadius = BorderRadius.all(Radius.circular(button));
  static const BorderRadius mdRadius = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgRadius = BorderRadius.all(Radius.circular(lg));
}

/// Elevation scale (Stage G of the aesthetics pass, 2026-09-27) — six named
/// levels, low to high: [flat] (inline content — chips, list rows) <
/// [card] (resting cards/tiles) < [raised] (a card mid-press-lift, see
/// Stage M's card-lift-on-tap) < [selected] (an active/selected state — a
/// chosen chip, active tab, selected list row) < [floating] (FABs,
/// snackbars — small controls that must always read as "on top") <
/// [overlay] (dialogs, bottom sheets, full modals — the highest tier,
/// meant to be paired with a blurred backdrop, see Stage J).
///
/// Named by what the elevation is FOR, not just a bare number, so a call
/// site reads as intent ("this is a dialog" / `AppElevation.overlay`)
/// rather than a magic `6`.
///
/// [shadowsFor] is the real depth system: a soft, two-layer shadow (a
/// wide, faint "ambient" layer plus a tighter, more visible "contact"
/// layer) rather than Flutter Material's single built-in umbra+penumbra
/// shadow — that single-shadow look is exactly what reads as flat and
/// "AI-generated" at a glance. Every level uses the same TWO-layer shape,
/// just larger/darker the higher it sits, so the whole scale reads as one
/// consistent system rather than a different shadow style per widget.
class AppElevation {
  AppElevation._();

  static const double flat = 0;
  static const double card = 1;
  static const double raised = 3;
  static const double selected = 4;
  static const double floating = 6;
  static const double overlay = 12;

  /// The soft shadow for [level] (one of this class's own constants, or
  /// anything in between). [brightness] matters because a dark surface
  /// reads a black drop shadow far less than a light one does (see Stage
  /// O's own note on this) — dark scales both layers' opacity down and
  /// pushes them out slightly further, rather than reusing the light-mode
  /// values unchanged, which would look far too heavy on a dark surface.
  static List<BoxShadow> shadowsFor(double level, {Brightness brightness = Brightness.light}) {
    if (level <= flat) return const [];
    final dark = brightness == Brightness.dark;
    // Normalized 0-1 position on the scale — every dimension below scales
    // off this one number, so raising a level always raises every part of
    // its shadow together rather than needing separate hand-tuned values
    // per level.
    final t = (level / overlay).clamp(0.0, 1.0);

    final ambientOpacity = (dark ? 0.22 : 0.09) + t * (dark ? 0.10 : 0.09);
    final ambientBlur = 6 + t * 30;
    final ambientOffset = (dark ? 2 : 1) + t * 8;

    final contactOpacity = (dark ? 0.30 : 0.15) + t * (dark ? 0.14 : 0.11);
    final contactBlur = 2 + t * 7;
    final contactSpread = -0.5 - t * 1.5;
    final contactOffset = 1 + t * 4;

    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: ambientOpacity),
        blurRadius: ambientBlur,
        offset: Offset(0, ambientOffset),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: contactOpacity),
        blurRadius: contactBlur,
        spreadRadius: contactSpread,
        offset: Offset(0, contactOffset),
      ),
    ];
  }
}

/// Soft, on-brand gradients (Stage I of the aesthetics pass, 2026-09-27) —
/// 2-3 stops within the app's existing blue brand palette (see
/// `AppTheme.seed`/`.accent`), never a full-hue "rainbow" gradient. Two
/// shapes are exposed:
/// - [hero]: a wider color travel, for large brand surfaces (a home-screen
///   header, a splash) where the gradient itself is the visual interest.
/// - [primaryButton]: a deliberately much SUBTLER range (a small luminance
///   step, not a big color move) for [AppPrimaryButton]'s own fill — kept
///   tight specifically so the button's on-primary text stays legible at
///   every point across the gradient, not just at one end (checked against
///   Stage O's own WCAG contrast pass).
///
/// The lighter end always sits toward the top-left and the deeper end
/// toward the bottom-right on both — the same direction [AppElevation]'s
/// shadow already implies light comes from, so the two systems reinforce
/// one "light source" instead of quietly contradicting each other.
class AppGradients {
  AppGradients._();

  static LinearGradient hero(ColorScheme colorScheme) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          colorScheme.primary,
          Color.lerp(colorScheme.primary, colorScheme.primaryContainer, 0.55)!,
          colorScheme.primaryContainer,
        ],
      );

  static LinearGradient primaryButton(ColorScheme colorScheme) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(colorScheme.primary, Colors.white, 0.10)!,
          colorScheme.primary,
          Color.lerp(colorScheme.primary, Colors.black, 0.12)!,
        ],
      );

  /// For [FunctionButton]'s icon badge — a much tighter range still, built
  /// around `primaryContainer` rather than `primary`, so `onPrimaryContainer`
  /// (the icon's own color) keeps the contrast Material already designed it
  /// to have against that container tone.
  static LinearGradient iconBadge(ColorScheme colorScheme) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(colorScheme.primaryContainer, Colors.white, 0.12)!,
          colorScheme.primaryContainer,
        ],
      );
}
