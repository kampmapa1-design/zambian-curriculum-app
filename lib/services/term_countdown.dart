import '../models/zambian_term_calendar.dart';

/// Learner-facing "Countdown Term?" (owner request, 2026-09-29) — reuses
/// [computeZambianSchoolYear]'s real Ministry term dates exactly as the
/// Scheme of Work engine already does; no new data source. [daysRemaining]
/// excludes real Zambian public holidays (see
/// [daysUntilExcludingPublicHolidays]) — the same shared exclusion the
/// national exam countdown uses, per explicit request that both read from
/// one calendar source rather than two.
class TermCountdown {
  final int termNumber;
  final int year;

  /// False when [now] falls in a holiday (before Term 1 opens, the
  /// December break, or the gap between terms) — [daysRemaining] then
  /// counts down to this term's OPENING instead of a nonsensical negative
  /// number, and [referenceDate] is that open date rather than a close date.
  final bool isCurrentlyInTerm;
  final int daysRemaining;
  final DateTime referenceDate;

  const TermCountdown({
    required this.termNumber,
    required this.year,
    required this.isCurrentlyInTerm,
    required this.daysRemaining,
    required this.referenceDate,
  });
}

/// [now] normally the real current time; a parameter only so this is
/// directly testable without faking the system clock.
TermCountdown currentTermCountdown(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final thisYear = computeZambianSchoolYear(today.year);

  for (final term in thisYear.terms) {
    if (!today.isBefore(term.open) && !today.isAfter(term.close)) {
      return TermCountdown(
        termNumber: term.termNumber,
        year: today.year,
        isCurrentlyInTerm: true,
        daysRemaining: daysUntilExcludingPublicHolidays(today, term.close),
        referenceDate: term.close,
      );
    }
  }

  // On holiday — find the next term to open, whether that's still later
  // THIS year (before Term 1, or the ~1-month gap between terms) or Term 1
  // of next year (the December break).
  final candidates = [
    ...thisYear.terms.where((t) => t.open.isAfter(today)),
    computeZambianSchoolYear(today.year + 1).term(1),
  ];
  final upcoming = candidates.reduce((a, b) => a.open.isBefore(b.open) ? a : b);
  return TermCountdown(
    termNumber: upcoming.termNumber,
    year: upcoming.open.year,
    isCurrentlyInTerm: false,
    daysRemaining: daysUntilExcludingPublicHolidays(today, upcoming.open),
    referenceDate: upcoming.open,
  );
}
