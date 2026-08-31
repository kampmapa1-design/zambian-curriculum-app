/// The real Zambian Ministry of Education school-year calendar structure —
/// generated algorithmically for ANY year, not hardcoded per-year data.
///
/// **How this was derived (2026-08-29)**: the Ministry's own site
/// (edu.gov.zm) was down when this was needed, so the real "Early
/// Childhood, Primary and Secondary School Calendar 2026 to 2030"
/// document (Ng'Andu Edition, Ministry of Education letterhead/coat of
/// arms visually confirmed) was opened directly and read. Three years —
/// 2026, 2027, and 2028 — were fully read (every term's open/close/
/// mid-term-break date), and 2029/2030's Term 1 opening date was also
/// read. The formula below was checked against and exactly reproduces
/// all of that real data — see reference_zambia_school_calendar_2026_2030
/// memory for the source document and the raw dates that were read.
///
/// The verified rule:
/// - Term 1 opens the first Monday on or after 8 January.
/// - Every term runs exactly 13 Monday-to-Friday weeks (open = Monday of
///   week 1, close = Friday of week 13 = open + 88 days).
/// - Every term's mid-term break is week 7 of that term (Monday-Friday =
///   open + 42 to open + 46 days).
/// - The next term opens exactly 31 days after the previous term closes.
///
/// This lets the app compute a real, correctly-structured calendar for
/// any year — including years beyond 2030, where the real published
/// document doesn't reach — using the same rule the Ministry's own
/// calendar has consistently followed across every year actually checked.
/// Years beyond what was directly verified (2029 onward) are a confident
/// extrapolation of a rule confirmed against three full years and two
/// more partial ones, not a guess from nothing — but still genuinely an
/// extrapolation, not a re-confirmed official date, and worth re-checking
/// against a fresh official calendar if one becomes available for a
/// specific far-future year that matters for a real submission.
library;

class TermDates {
  final int termNumber;
  final DateTime open;
  final DateTime close;
  final DateTime midtermBreakStart;
  final DateTime midtermBreakEnd;

  const TermDates({
    required this.termNumber,
    required this.open,
    required this.close,
    required this.midtermBreakStart,
    required this.midtermBreakEnd,
  });

  /// Real weeks in this term (always 13 — see class doc).
  static const int totalWeeks = 13;

  /// Which week (1-13) the mid-term break falls on (always week 7).
  static const int midtermBreakWeek = 7;

  /// Which week (1-13) end-of-term examinations fall on — the last week
  /// of the term. Not part of the formally published Ministry calendar
  /// rule (see this file's class doc), but a real, overwhelmingly
  /// consistent pattern across every real sourced scheme of work checked
  /// this project has ingested — teachers reserve the term's final week
  /// for exams, never new content (added 2026-08-31, after a real report
  /// of generated schemes scheduling teaching content into week 13).
  static const int endOfTermWeek = totalWeeks;

  /// Real teaching weeks — every week except the mid-term break and the
  /// end-of-term examination week.
  static const int teachingWeekCount = totalWeeks - 2;

  /// The Monday that starts week [weekNumber] (1-13) of this term.
  DateTime weekStart(int weekNumber) => open.add(Duration(days: (weekNumber - 1) * 7));
}

class ZambianSchoolYearCalendar {
  final int year;
  final List<TermDates> terms;

  const ZambianSchoolYearCalendar({required this.year, required this.terms});

  TermDates term(int termNumber) => terms.firstWhere((t) => t.termNumber == termNumber);
}

/// Computes the real Zambian 3-term school-year calendar for [year] —
/// see this file's own doc comment for the verified rule and how it was
/// derived.
ZambianSchoolYearCalendar computeZambianSchoolYear(int year) {
  DateTime firstMondayOnOrAfter(DateTime date) {
    // DateTime.weekday: Monday = 1 ... Sunday = 7.
    final daysToAdd = (8 - date.weekday) % 7;
    return date.add(Duration(days: daysToAdd));
  }

  final terms = <TermDates>[];
  var open = firstMondayOnOrAfter(DateTime(year, 1, 8));
  for (var termNumber = 1; termNumber <= 3; termNumber++) {
    final close = open.add(const Duration(days: 88));
    final midtermStart = open.add(const Duration(days: 42));
    final midtermEnd = open.add(const Duration(days: 46));
    terms.add(TermDates(
      termNumber: termNumber,
      open: open,
      close: close,
      midtermBreakStart: midtermStart,
      midtermBreakEnd: midtermEnd,
    ));
    open = close.add(const Duration(days: 31));
  }
  return ZambianSchoolYearCalendar(year: year, terms: terms);
}
