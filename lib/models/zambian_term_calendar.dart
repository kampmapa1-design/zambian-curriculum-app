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
/// Real Zambian public holidays — added 2026-09-29 to this SAME file
/// (per explicit request: one calendar data source, not a second dataset
/// alongside it) after auditing [TermDates]/[computeZambianSchoolYear] and
/// confirming they only ever tracked term open/close and mid-term-break
/// WEEKS, never individual public holiday DATES. Sourced from Wikipedia's
/// "Public holidays in Zambia" (cross-checked against a second source for
/// the fixed dates, and against the real, independently-verified 2026
/// Easter Sunday date — 5 April 2026 — for the Easter-weekend rule) rather
/// than invented: Chapter 272 of Zambia's laws lets the President add/
/// remove holidays, so treat this as the well-established real set, not a
/// government-guaranteed-immutable one.
///
/// - Fixed dates: New Year's Day (1 Jan), International Women's Day
///   (8 Mar), Youth Day (12 Mar), Kenneth Kaunda's Birthday (28 Apr),
///   Labour Day (1 May), Africa Freedom Day (25 May), National Day of
///   Prayer, Fasting, Repentance and Reconciliation (18 Oct), Independence
///   Day (24 Oct), Christmas Day (25 Dec). If any of these falls on a
///   Sunday, the following Monday is the observed holiday too (both dates
///   are included — the calendar date itself is still genuinely non-
///   working even if the "official" observance shifts).
/// - Movable: Heroes' Day (first Monday in July), Unity Day (the Tuesday
///   immediately after — NOT simply "first Tuesday in July", since in a
///   year where 1 July is a Tuesday, Heroes' Day is still the FIRST
///   MONDAY, meaning 7 July, so Unity Day is 8 July, not 1 July), Farmers'
///   Day (first Monday in August), and all four days of the Easter
///   weekend (Good Friday, Holy Saturday, Easter Sunday, Easter Monday) —
///   Zambia observes the full four-day weekend as public holidays, not
///   just Good Friday/Easter Monday as many countries do.
List<DateTime> zambianPublicHolidays(int year) {
  DateTime firstMondayOnOrAfter(DateTime date) {
    final daysToAdd = (8 - date.weekday) % 7;
    return date.add(Duration(days: daysToAdd));
  }

  final easter = _computeEasterSunday(year);
  final heroesDay = firstMondayOnOrAfter(DateTime(year, 7, 1));

  final fixed = [
    DateTime(year, 1, 1), // New Year's Day
    DateTime(year, 3, 8), // International Women's Day
    DateTime(year, 3, 12), // Youth Day
    DateTime(year, 4, 28), // Kenneth Kaunda's Birthday
    DateTime(year, 5, 1), // Labour Day
    DateTime(year, 5, 25), // Africa Freedom Day
    DateTime(year, 10, 18), // National Day of Prayer
    DateTime(year, 10, 24), // Independence Day
    DateTime(year, 12, 25), // Christmas Day
  ];

  final holidays = <DateTime>[
    ...fixed,
    // A fixed holiday landing on a Sunday is also observed the next
    // Monday — both are genuinely non-teaching days.
    for (final h in fixed)
      if (h.weekday == DateTime.sunday) h.add(const Duration(days: 1)),
    heroesDay,
    heroesDay.add(const Duration(days: 1)), // Unity Day
    firstMondayOnOrAfter(DateTime(year, 8, 1)), // Farmers' Day
    easter.subtract(const Duration(days: 2)), // Good Friday
    easter.subtract(const Duration(days: 1)), // Holy Saturday
    easter, // Easter Sunday
    easter.add(const Duration(days: 1)), // Easter Monday
  ];
  holidays.sort();
  return holidays;
}

/// The Anonymous Gregorian algorithm (Meeus/Jones/Butcher) for the date of
/// Easter Sunday in the Gregorian calendar — standard, verifiable public-
/// domain math, not a lookup table. Checked against the real, independently
/// confirmed 2026 Easter Sunday (5 April 2026) before use here.
DateTime _computeEasterSunday(int year) {
  final a = year % 19;
  final b = year ~/ 100;
  final c = year % 100;
  final d = b ~/ 4;
  final e = b % 4;
  final f = (b + 8) ~/ 25;
  final g = (b - f + 1) ~/ 3;
  final h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4;
  final k = c % 4;
  final l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final month = (h + l - 7 * m + 114) ~/ 31;
  final day = (h + l - 7 * m + 114) % 31 + 1;
  return DateTime(year, month, day);
}

/// Calendar days from [from] to [to] (inclusive of [to], exclusive of
/// [from] — i.e. "how many days until [to]") with Zambian public holidays
/// subtracted, per the owner's explicit "public holidays already excluded"
/// requirement for the countdown features (2026-09-29) — the SAME
/// [zambianPublicHolidays] data both Fix 4 (term countdown) and the
/// national exam countdown read from, never two separately-maintained
/// exclusion lists. Weekends are NOT excluded — only real holiday dates —
/// matching the requirement literally ("public holidays," not "school
/// days"). Never negative: if [to] is on/before [from], returns 0.
int daysUntilExcludingPublicHolidays(DateTime from, DateTime to) {
  final start = DateTime(from.year, from.month, from.day);
  final end = DateTime(to.year, to.month, to.day);
  if (!end.isAfter(start)) return 0;

  final rawDays = end.difference(start).inDays;
  final holidayDates = <DateTime>{
    for (var y = start.year; y <= end.year; y++)
      for (final h in zambianPublicHolidays(y)) DateTime(h.year, h.month, h.day),
  };
  final excluded = holidayDates.where((h) => h.isAfter(start) && !h.isAfter(end)).length;
  return rawDays - excluded;
}

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
