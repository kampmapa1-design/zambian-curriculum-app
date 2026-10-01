import 'package:flutter/material.dart';

/// A [LinearProgressIndicator] whose value CHANGES animate smoothly (Stage
/// M of the aesthetics pass, 2026-09-27: "a gentle progress-bar fill rather
/// than an instant jump") instead of the bar snapping straight to the new
/// position every time — e.g. as a batch-marking run finishes one more
/// script. `null` still means indeterminate, unchanged.
class AppAnimatedLinearProgress extends StatelessWidget {
  const AppAnimatedLinearProgress({
    super.key,
    required this.value,
    this.minHeight,
    this.borderRadius,
  });

  final double? value;
  final double? minHeight;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final target = value;
    if (target == null) {
      return LinearProgressIndicator(minHeight: minHeight, borderRadius: borderRadius);
    }
    // TweenAnimationBuilder's own documented behavior is exactly this: when
    // `end` changes between rebuilds, it animates from wherever the bar
    // currently sits to the new value, rather than restarting from `begin`
    // — `begin: 0` only ever applies on the very first build.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target.clamp(0, 1)),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      builder: (context, animatedValue, _) =>
          LinearProgressIndicator(value: animatedValue, minHeight: minHeight, borderRadius: borderRadius),
    );
  }
}
