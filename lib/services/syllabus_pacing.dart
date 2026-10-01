import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../models/zambian_term_calendar.dart';

/// "Syllabus Inspection" (owner request, 2026-09-29, redirected to a
/// zero-cost version — see [[project-smart-teacher-learner-countdown-and-exam-timetable]]
/// memory): the syllabus's own real, bundled topic order for [template],
/// plus an honest APPROXIMATION of where the school year currently sits
/// in that order.
///
/// Real, disclosed limitation: only a handful of bundled subjects have
/// genuine per-topic sourced week data (`SchemeOfWorkEntry.realWeekNumber`)
/// — most don't (see the app's own content-coverage notes). Rather than
/// pretend precision that doesn't exist for most subjects, this always
/// falls back to simple, honest proportional pacing across the WHOLE
/// school year (how many of the year's real teaching days have passed,
/// applied to the topic list's own real length) — clearly labelled as an
/// approximation in the UI, never presented as a tracked completion record.
class SyllabusPacingResult {
  final List<SchemeOfWorkEntry> entries;

  /// Index into [entries] for "approximately here now" — -1 if [entries]
  /// is empty (nothing to show at all).
  final int approximateCurrentIndex;

  const SyllabusPacingResult({required this.entries, required this.approximateCurrentIndex});
}

SyllabusPacingResult syllabusPacingFor(SyllabusTemplate template, {DateTime? now}) {
  final entries = allSchemeOfWorkEntries(template);
  if (entries.isEmpty) return const SyllabusPacingResult(entries: [], approximateCurrentIndex: -1);

  final today = now ?? DateTime.now();
  final year = computeZambianSchoolYear(today.year);
  final yearStart = year.term(1).open;
  final yearEnd = year.term(3).close;
  final totalSpan = yearEnd.difference(yearStart).inDays;

  double fraction;
  if (totalSpan <= 0 || today.isBefore(yearStart)) {
    fraction = 0.0;
  } else if (today.isAfter(yearEnd)) {
    fraction = 1.0;
  } else {
    fraction = today.difference(yearStart).inDays / totalSpan;
  }

  final index = (fraction * (entries.length - 1)).round().clamp(0, entries.length - 1);
  return SyllabusPacingResult(entries: entries, approximateCurrentIndex: index);
}
