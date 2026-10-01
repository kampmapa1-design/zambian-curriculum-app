import 'package:flutter/material.dart';

/// The app-wide "something just succeeded" moment — pop in, hold, fade —
/// extracted from [ScorePopBadge] (Chief Marker's own score notice, left
/// untouched since it already ships and works) so the same considered
/// animation is available as the standard success-state pattern anywhere
/// else in the app (Scheme of Work generation, Report Form save, etc.)
/// rather than each screen inventing its own one-off feedback. Purely a
/// momentary notice — never blocks input ([IgnorePointer]) and carries no
/// state of its own once [onDone] fires.
class PopFadeBadge extends StatefulWidget {
  const PopFadeBadge({
    super.key,
    required this.child,
    required this.onDone,
    this.holdDuration = const Duration(milliseconds: 900),
    this.totalDuration = const Duration(milliseconds: 3500),
  });

  /// The badge's content — typically a small [Column] of text, styled by
  /// the caller (see [ScorePopBadge] for the reference shape).
  final Widget child;
  final VoidCallback onDone;

  /// How long the badge stays fully visible before starting to fade.
  final Duration holdDuration;

  /// Total lifetime — [onDone] fires at this point regardless of the fade
  /// animation's own duration, so a caller can always rely on it as "this
  /// badge is done" without inspecting animation state.
  final Duration totalDuration;

  @override
  State<PopFadeBadge> createState() => _PopFadeBadgeState();
}

class _PopFadeBadgeState extends State<PopFadeBadge> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // Pop in on the next frame (so the initial build starts from
    // invisible/small, giving the scale-in something to animate from),
    // hold briefly at full visibility, then fade.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
    Future.delayed(widget.holdDuration, () {
      if (mounted) setState(() => _visible = false);
    });
    Future.delayed(widget.totalDuration, widget.onDone);
  }

  @override
  Widget build(BuildContext context) {
    final fadeOutDuration = widget.totalDuration - widget.holdDuration;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: Duration(milliseconds: _visible ? 250 : fadeOutDuration.inMilliseconds.clamp(250, 1 << 30)),
        curve: _visible ? Curves.easeOut : Curves.easeIn,
        child: AnimatedScale(
          scale: _visible ? 1.0 : 0.85,
          duration: const Duration(milliseconds: 250),
          curve: Curves.elasticOut,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
