import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// The app's standard "pick a major function" button — a full-width card
/// with a leading icon, title, subtitle, and trailing chevron. Extracted
/// (2026-09-02) from `home_screen.dart`'s private `_FunctionButton` so the
/// same styling is reusable on sub-menu screens (e.g.
/// TeachingResourcesMenuScreen, AssignmentsTestsMenuScreen) that group a
/// few related functions behind one home-screen entry point, keeping
/// every "pick a function" screen in this app visually consistent.
class FunctionButton extends StatefulWidget {
  const FunctionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<FunctionButton> createState() => _FunctionButtonState();
}

class _FunctionButtonState extends State<FunctionButton> with SingleTickerProviderStateMixin {
  // Stage M (micro-interactions, 2026-09-27): "a subtle card-lift-on-tap
  // before navigation" — a brief, real state change (about to navigate),
  // not decorative motion, and well under the spec's own ~300ms ceiling.
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 110));
  bool _navigating = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (_navigating) return;
    _navigating = true;
    await _controller.forward();
    if (!mounted) return;
    await _controller.reverse();
    _navigating = false;
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Transform.translate(
          offset: Offset(0, -2 * t),
          child: Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            decoration: BoxDecoration(
              borderRadius: AppRadius.mdRadius,
              // Stage G (elevation/depth token system, 2026-09-27): a soft,
              // two-layer shadow from the shared token scale, in place of a
              // plain `Card(elevation: ...)` — this is the app's most-repeated
              // "pick a function" surface (home screen + every sub-menu), so
              // upgrading it here is the single highest-leverage place to prove
              // the new depth system out. The lift (above) briefly raises this
              // toward AppElevation.raised while a tap is in flight.
              boxShadow: AppElevation.shadowsFor(
                AppElevation.card + (AppElevation.raised - AppElevation.card) * t,
                brightness: theme.brightness,
              ),
              // Stage O (accessibility, 2026-09-27) — a real finding, not
              // assumed: Material 3's own tonal card/background separation
              // (this Card's default `surfaceContainerLow` fill against the
              // Scaffold's `surface`) never reaches WCAG 1.4.11's 3:1
              // non-text-contrast minimum for a UI-component boundary, in
              // EITHER theme, however high a surface-container tier is
              // picked — the tonal system is designed to pair with a real
              // shadow and/or outline, not stand alone. `colorScheme.outline`
              // does clear 3:1 in both themes (verified in
              // test/app_accessibility_final_test.dart) and is exactly the
              // token Material 3 reserves for this — so the shadow above is
              // paired with a real, checked border, not relying on the
              // tonal step or the shadow alone.
              // Full opacity, deliberately — fading this toward the
              // background (as an earlier draft of this fix mistakenly
              // did) would undo the very 3:1 guarantee this border exists
              // for; `colorScheme.outline` is already the "quiet border"
              // tone, not something that also needs its own transparency.
              border: Border.all(color: theme.colorScheme.outline, width: 0.75),
            ),
            child: child,
          ),
        );
      },
      // Card itself still supplies the Material surface color/clip/ink —
      // elevation 0 so it contributes no shadow of its own; the Container
      // above is the only shadow source.
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdRadius),
        child: InkWell(
          borderRadius: AppRadius.mdRadius,
          onTap: _handleTap,
          child: Semantics(
            button: true,
            label: '${widget.label}. ${widget.subtitle}',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              child: ListTile(
                // Stage I (gradients, 2026-09-27): a soft gradient badge in
                // place of CircleAvatar's flat fill — CircleAvatar itself
                // only takes a solid backgroundColor, so a plain gradient
                // Container stands in for it here.
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AppGradients.iconBadge(theme.colorScheme),
                  ),
                  child: Icon(widget.icon, color: theme.colorScheme.onPrimaryContainer),
                ),
                title: Text(widget.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(widget.subtitle),
                trailing: const Icon(Icons.chevron_right_outlined),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
