import 'package:flutter/material.dart';

import '../models/timetable.dart';

const kTimetableWeekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// The day × period grid shared across every timetable view — the
/// whole-school/class view (GeneratedTimetableScreen), and Stage 11's
/// per-teacher view (TeacherTimetableScreen). Extracted from what was
/// originally GeneratedTimetableScreen's private `_ClassGrid` so both
/// screens render lessons identically ("same visual format as the class
/// timetable" is Stage 11's own requirement) instead of drifting apart.
/// [cellSubtitle] is what varies: the class view shows the teacher's
/// name per cell, the teacher view shows the class's name per cell.
class TimetableGrid extends StatelessWidget {
  const TimetableGrid({
    required this.assignments,
    required this.periodsPerDay,
    required this.teachingDaysPerWeek,
    required this.cellSubtitle,
    this.onCellTap,
    super.key,
  });

  final List<TimetableAssignment> assignments;
  final int periodsPerDay;
  final int teachingDaysPerWeek;
  final String Function(TimetableAssignment) cellSubtitle;
  final ValueChanged<TimetableAssignment>? onCellTap;

  @override
  Widget build(BuildContext context) {
    final byDayPeriod = {for (final a in assignments) '${a.day}_${a.period}': a};
    final days = teachingDaysPerWeek.clamp(0, 7);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        border: TableBorder.all(color: Theme.of(context).colorScheme.outlineVariant),
        defaultColumnWidth: const FixedColumnWidth(110),
        children: [
          TableRow(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest),
            children: [
              const Padding(padding: EdgeInsets.all(6), child: Text('Period', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              for (var d = 0; d < days; d++)
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(kTimetableWeekdayLabels[d], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
            ],
          ),
          for (var p = 0; p < periodsPerDay; p++)
            TableRow(
              children: [
                Padding(padding: const EdgeInsets.all(6), child: Text('${p + 1}', style: const TextStyle(fontSize: 12))),
                for (var d = 0; d < days; d++) _cell(context, byDayPeriod['${d}_$p']),
              ],
            ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, TimetableAssignment? a) {
    if (a == null) return const Padding(padding: EdgeInsets.all(6), child: Text('—', style: TextStyle(fontSize: 11, color: Colors.grey)));
    final content = Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text(a.subjectName, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600))),
              if (a.locked) Icon(Icons.lock_outline, size: 12, color: Theme.of(context).colorScheme.primary),
            ],
          ),
          Text(cellSubtitle(a), style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
    if (onCellTap == null) return content;
    // Material(type: transparency) so this InkWell never depends on an
    // ancestor Material actually being present — found by a real widget
    // test (2026-09-14): every current caller happens to sit inside a
    // Scaffold, which silently supplied one, but that's an implicit
    // dependency this widget shouldn't rely on to avoid crashing.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: () => onCellTap!(a), child: content),
    );
  }
}
