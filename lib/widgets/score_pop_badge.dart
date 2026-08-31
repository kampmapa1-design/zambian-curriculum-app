import 'package:flutter/material.dart';

/// A student's score, popping in then fading away over roughly 3.5
/// seconds — fired once per script the moment AI grading finishes for it.
/// Shared by MarkingQueueScreen's batch "Process" flow and
/// ScriptBatchCaptureScreen's per-script "Mark it now?" flow (2026-08-31 —
/// extracted from MarkingQueueScreen since the capture screen is the more
/// common real path a teacher marks through, and the pop-up wasn't wired
/// there at all originally). Purely a momentary notice — it never blocks
/// input ([IgnorePointer]) and carries no state of its own once [onDone]
/// fires.
class ScorePopBadge extends StatefulWidget {
  const ScorePopBadge({super.key, required this.studentName, required this.percent, required this.onDone});

  final String studentName;
  final double percent;
  final VoidCallback onDone;

  @override
  State<ScorePopBadge> createState() => _ScorePopBadgeState();
}

class _ScorePopBadgeState extends State<ScorePopBadge> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // Pop in on the next frame (so the initial build starts from
    // invisible/small, giving the scale-in something to animate from),
    // hold briefly at full visibility, then fade — ~3.5s total.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _visible = false);
    });
    Future.delayed(const Duration(milliseconds: 3500), widget.onDone);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: Duration(milliseconds: _visible ? 250 : 2400),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.studentName, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.percent.toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
