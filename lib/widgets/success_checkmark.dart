import 'package:flutter/material.dart';

/// A brief, satisfying "done" animation (Stage M of the aesthetics pass,
/// 2026-09-27) — a checkmark that pops in with a small spring/overshoot,
/// tied to a real completed action (a batch marking run finishing), never
/// decorative motion on its own. ~260ms to pop in — comfortably under the
/// spec's own "under ~300ms" ceiling for a single animation.
class SuccessCheckmark extends StatefulWidget {
  const SuccessCheckmark({super.key, this.size = 32});

  final double size;

  @override
  State<SuccessCheckmark> createState() => _SuccessCheckmarkState();
}

class _SuccessCheckmarkState extends State<SuccessCheckmark> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260))..forward();
  late final Animation<double> _scale = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ScaleTransition(
      scale: _scale,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: colorScheme.primary),
        child: Icon(Icons.check_outlined, color: colorScheme.onPrimary, size: widget.size * 0.65),
      ),
    );
  }
}
