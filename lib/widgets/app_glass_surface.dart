import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// Frosted-glass surface (Stage J of the aesthetics pass, 2026-09-27) — a
/// background blur, a translucent surface tint, and a subtle border, so an
/// overlay visibly reads as FLOATING above whatever's behind it rather
/// than looking like just another flat screen.
///
/// Reserved for real overlays — dialogs, bottom sheets, anything presented
/// above existing content — never an ordinary page's own background: that
/// would be the same "apply it everywhere and nothing reads as special
/// anymore" trap [AppPrimaryButton]'s own doc comment already warns about
/// for Stage H, and a frosted WHOLE page also hurts the legibility of any
/// content-dense screen sitting on it (see this file's own accessibility
/// tests: the tint alpha below is deliberately conservative — checked
/// against BOTH a worst-case black and white backdrop, not assumed).
class AppGlassSurface extends StatelessWidget {
  const AppGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = AppRadius.lgRadius,
    this.blurSigma = 18,
    this.padding,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final EdgeInsetsGeometry? padding;

  /// How opaque the surface tint is, regardless of [brightness] — kept
  /// high enough that body text stays WCAG AA legible even over a
  /// worst-case backdrop (verified in `test/app_glass_surface_test.dart`),
  /// while still translucent enough to read as genuine frosted glass
  /// rather than an ordinary flat card.
  static double tintAlpha(Brightness brightness) => brightness == Brightness.dark ? 0.88 : 0.90;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: tintAlpha(theme.brightness)),
            borderRadius: borderRadius,
            border: Border.all(
              color: (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.12 : 0.08),
            ),
          ),
          // Real production bug caught by this widget's own tests: content
          // that itself relies on a Material ancestor (a ListTile in a
          // bottom sheet, most commonly) would otherwise throw
          // "No Material widget found" — Flutter's own Dialog/bottom-sheet
          // machinery always provides one, so this must too.
          // `transparency` so it contributes no paint of its own — the
          // Container above is the only visible surface.
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// The blurred backdrop behind the surface itself — visible through the
/// gap between the surface's edge and the screen edge, and (being a
/// SEPARATE, screen-covering blur layer under the transition) what makes
/// the page behind genuinely read as blurred, not just the dialog card.
Widget _blurredBarrier(Animation<double> animation, Widget? child) => BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 6 * animation.value, sigmaY: 6 * animation.value),
      child: FadeTransition(opacity: animation, child: child),
    );

/// A glass-styled stand-in for `showDialog` + `AlertDialog` — same
/// title/content/actions shape as the AlertDialog calls it replaces, so
/// converting a call site is a direct swap. See [AppGlassSurface]'s own
/// doc comment for when this is (and isn't) the right choice.
Future<T?> showAppGlassAlertDialog<T>(
  BuildContext context, {
  required String title,
  required Widget content,
  required List<Widget> actions,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.15),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final theme = Theme.of(dialogContext);
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: AppGlassSurface(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleLarge),
                  const SizedBox(height: AppSpacing.sm),
                  content,
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (var i = 0; i < actions.length; i++)
                        Padding(padding: EdgeInsets.only(left: i == 0 ? 0 : AppSpacing.xs), child: actions[i]),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) => _blurredBarrier(animation, child),
  );
}

/// A glass-styled stand-in for `showModalBottomSheet` — natural (not
/// scroll-controlled) content height, sitting on [AppGlassSurface] instead
/// of a flat sheet. Fine for an ordinary picker-style sheet (a `Wrap`/
/// `Column` of `ListTile`s); NOT a drop-in for a sheet built around
/// `DraggableScrollableSheet` or other height-negotiating content, which
/// needs the full-screen height bounds a real `showModalBottomSheet` route
/// gives it — those keep using `showModalBottomSheet` directly.
Future<T?> showAppGlassBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: isDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.15),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, animation, secondaryAnimation) => Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(dialogContext).size.height * 0.9),
        child: AppGlassSurface(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          // A ScrollView, not a bare child: content taller than the 0.9
          // cap above scrolls instead of overflowing — the same
          // real-world safety net `showModalBottomSheet` itself relies on
          // for arbitrary caller content.
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: builder(dialogContext),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) => _blurredBarrier(
      animation,
      SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
        child: child,
      ),
    ),
  );
}
