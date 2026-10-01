import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// The app's primary call-to-action button (Stage H of the aesthetics
/// pass, 2026-09-27) — a genuine tactile "pressable" button: a soft
/// highlight along the upper-left edge and a dark [AppElevation.selected]
/// shadow toward the lower-right at rest, giving it a raised, 3D look. On
/// press it visibly SINKS — the shadows pull inward and shrink and the
/// button scales down a hair — over ~130ms, then eases back out on
/// release, rather than the flat highlight-color tap state Material's
/// default button gives.
///
/// Deliberately reserved for the ONE true primary action on a screen —
/// the main Generate/Submit/Mark/Approve/Export button — never for every
/// button. That restraint is the point: this is exactly the failure mode
/// that made full-page neumorphism fall out of favor (everything looks
/// tactile, so nothing reads as more important, and soft low-contrast
/// shadows lose a clear tap boundary at scale — see Stage O's own
/// contrast/tap-boundary check). Every other button in the app keeps its
/// ordinary FilledButton/OutlinedButton styling from [AppTheme].
class AppPrimaryButton extends StatefulWidget {
  const AppPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.loading = false,
    this.expand = true,
  });

  final String label;

  /// Shown to the left of [label]; replaced by a spinner while [loading].
  final IconData? icon;

  final VoidCallback? onPressed;

  /// Swaps [icon] for a small spinner and disables the button — the same
  /// "mid-action" state every screen's own `_exporting`/`_generating`-style
  /// bool already tracks; this widget just renders it consistently.
  final bool loading;

  /// True (default) fills the available width, matching how a primary CTA
  /// is normally placed (a bottom bar, a full-width form action). False
  /// sizes to its content, for a primary action sitting inline.
  final bool expand;

  @override
  State<AppPrimaryButton> createState() => _AppPrimaryButtonState();
}

class _AppPrimaryButtonState extends State<AppPrimaryButton> with SingleTickerProviderStateMixin {
  // "roughly 100-150ms" per the Stage H spec; release eases back out a
  // touch slower than the press-in, so the sink reads as sudden and the
  // recovery as a gentler settle rather than symmetric and mechanical.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _pressed = CurvedAnimation(parent: _controller, curve: Curves.easeOut, reverseCurve: Curves.easeOut);

  bool get _disabled => widget.onPressed == null || widget.loading;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (_disabled) return;
    if (pressed) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    const radius = AppRadius.buttonRadius;
    final dark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _pressed,
      builder: (context, child) {
        final t = _pressed.value; // 0 = resting/raised, 1 = fully sunken
        final restShadows = AppElevation.shadowsFor(AppElevation.selected, brightness: theme.brightness);
        final shadows = [
          for (final s in restShadows)
            BoxShadow(
              color: s.color,
              // Pulled in and shrunk toward the surface — a real sink,
              // not just a fade — rather than only lerping toward a bare
              // "no shadow" end state.
              blurRadius: s.blurRadius * (1 - t * 0.65),
              spreadRadius: s.spreadRadius,
              offset: s.offset * (1 - t * 0.7),
            ),
        ];
        // The upper-left highlight half of the dual-shadow illusion —
        // fades out as the button sinks, since a sunken surface has
        // nothing left to catch the light.
        final highlight = BoxShadow(
          color: Colors.white.withValues(alpha: (dark ? 0.05 : 0.5) * (1 - t)),
          blurRadius: 5,
          spreadRadius: -2,
          offset: const Offset(-2, -2) * (1 - t),
        );

        return Transform.scale(
          scale: 1 - (t * 0.02),
          child: Container(
            width: widget.expand ? double.infinity : null,
            decoration: BoxDecoration(
              // Stage I (gradients, 2026-09-27): a soft, subtle gradient
              // fill in place of a flat color — disabled stays flat (an
              // inert-looking surface, no gradient, no shadow) so the
              // gradient itself reads as "this is active/tappable".
              color: _disabled ? colorScheme.surfaceContainerHighest : null,
              gradient: _disabled ? null : AppGradients.primaryButton(colorScheme),
              borderRadius: radius,
              boxShadow: _disabled ? const [] : [highlight, ...shadows],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: radius,
                onTap: _disabled ? null : widget.onPressed,
                onHighlightChanged: _setPressed,
                // The shadow squish IS the tactile feedback here — suppress
                // Material's own flat splash/highlight color so the two
                // don't compete (see this file's own doc comment).
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.loading)
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _disabled ? colorScheme.onSurfaceVariant : colorScheme.onPrimary,
                          ),
                        )
                      else if (widget.icon != null)
                        Icon(widget.icon, color: _disabled ? colorScheme.onSurfaceVariant : colorScheme.onPrimary),
                      if (widget.loading || widget.icon != null) const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: Text(
                          widget.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _disabled ? colorScheme.onSurfaceVariant : colorScheme.onPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
