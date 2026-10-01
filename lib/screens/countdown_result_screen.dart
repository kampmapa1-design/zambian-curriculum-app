import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// Shared results screen for BOTH "Countdown Term?" and "Countdown to
/// [year] National Exams?" (owner request, 2026-09-29) — a static
/// declaration first, then a live, continuously-ticking digital-watch-style
/// clock, styled with the app's real depth/gradient tokens
/// ([AppGradients]/[AppElevation]) rather than a plain default clock widget.
///
/// [daysRemaining] is the holiday-excluded headline figure (see
/// `daysUntilExcludingPublicHolidays`) — the number the static declaration
/// shows. [targetDate] is the real calendar moment the LIVE clock ticks
/// down to (end of day on the reference date); it deliberately does NOT
/// skip over holidays itself, since a continuously-ticking clock can't
/// "jump" without looking broken — the two numbers are complementary, not
/// required to match exactly, and the caption under the clock says so.
///
/// Exam-specific colour states (owner request, 2026-09-29, refining Fix 6)
/// — [isExamCountdown] scopes these to the national-exam countdown only,
/// never the plain term countdown, since the request was specifically
/// "before the beginning of the national exam"/"once the exam begins":
/// the clock digits turn red once one week (7 days) or less remains before
/// [targetDate] (the exam period's own start), then green from the moment
/// [targetDate] is reached, with "Examinations In Progress" shown below
/// the clock for as long as `DateTime.now()` is on or before
/// [examEndDate] — a real, AI-extracted-and-confirmed date (see
/// NationalExamTimetableAdminScreen), never guessed. If [examEndDate] is
/// null (an older saved timetable, or a document whose end date genuinely
/// wasn't legible), the green/"in progress" state is shown indefinitely
/// from [targetDate] onward rather than silently guessing when it ends.
class CountdownResultScreen extends StatefulWidget {
  const CountdownResultScreen({
    super.key,
    required this.title,
    required this.daysRemaining,
    required this.targetDate,
    this.subtitle,
    this.isExamCountdown = false,
    this.examEndDate,
  });

  final String title;
  final int daysRemaining;
  final DateTime targetDate;
  final String? subtitle;
  final bool isExamCountdown;
  final DateTime? examEndDate;

  @override
  State<CountdownResultScreen> createState() => _CountdownResultScreenState();
}

class _CountdownResultScreenState extends State<CountdownResultScreen> {
  late Timer _timer;
  late Duration _remaining;
  bool _colonVisible = true;

  @override
  void initState() {
    super.initState();
    _remaining = _computeRemaining();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _remaining = _computeRemaining();
        _colonVisible = !_colonVisible;
      });
    });
  }

  Duration _computeRemaining() {
    final diff = widget.targetDate.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  bool get _examStarted => widget.isExamCountdown && !DateTime.now().isBefore(widget.targetDate);

  bool get _examInRedWindow =>
      widget.isExamCountdown && !_examStarted && _remaining <= const Duration(days: 7);

  bool get _examInProgress {
    if (!_examStarted) return false;
    final end = widget.examEndDate;
    if (end == null) return true;
    final endOfDay = DateTime(end.year, end.month, end.day, 23, 59, 59);
    return !DateTime.now().isAfter(endOfDay);
  }

  Color? get _clockColor {
    if (_examInProgress) return Colors.green.shade700;
    if (_examInRedWindow) return Colors.red.shade700;
    return null;
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final d = _remaining.inDays;
    final h = _remaining.inHours % 24;
    final m = _remaining.inMinutes % 60;
    final s = _remaining.inSeconds % 60;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg, horizontal: AppSpacing.md),
              decoration: BoxDecoration(
                gradient: AppGradients.hero(colorScheme),
                borderRadius: AppRadius.lgRadius,
                boxShadow: AppElevation.shadowsFor(AppElevation.raised, brightness: brightness),
              ),
              child: Column(
                children: [
                  Text(
                    '${widget.daysRemaining} day${widget.daysRemaining == 1 ? '' : 's'} remaining',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: colorScheme.onPrimary,
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  if (widget.subtitle != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      widget.subtitle!,
                      style: TextStyle(color: colorScheme.onPrimary.withValues(alpha: 0.9)),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Container(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg, horizontal: AppSpacing.sm),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: AppRadius.lgRadius,
                border: Border.all(color: colorScheme.outline, width: 0.75),
                boxShadow: AppElevation.shadowsFor(AppElevation.card, brightness: brightness),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _clockSegment(context, d, 'days'),
                  _colon(context),
                  _clockSegment(context, h, 'hrs'),
                  _colon(context),
                  _clockSegment(context, m, 'min'),
                  _colon(context),
                  _clockSegment(context, s, 'sec'),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _examInProgress
                  ? 'Examinations In Progress'
                  : _remaining == Duration.zero
                      ? "It's here!"
                      : '(school holidays already excluded from the total above)',
              style: _examInProgress
                  ? Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.green.shade700,
                        fontWeight: FontWeight.bold,
                      )
                  : Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _clockSegment(BuildContext context, int value, String label) {
    return Column(
      children: [
        Text(
          value.toString().padLeft(2, '0'),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 30,
            fontWeight: FontWeight.bold,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: _clockColor,
          ),
        ),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }

  Widget _colon(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: AnimatedOpacity(
          opacity: _colonVisible ? 1 : 0.15,
          duration: const Duration(milliseconds: 200),
          child: Text(':', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _clockColor)),
        ),
      );
}
