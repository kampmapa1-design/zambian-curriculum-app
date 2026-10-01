import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/zambian_term_calendar.dart';

/// Real Zambian public holidays (owner request, 2026-09-29 — "Fix 5"):
/// guards the one thing that's easy to get subtly wrong here — the Easter
/// algorithm and the movable-holiday rules — against the real, independently
/// verified 2026 dates (Easter Sunday 5 April 2026, confirmed via web
/// search before writing this).
void main() {
  group('zambianPublicHolidays(2026)', () {
    late List<DateTime> holidays;
    setUp(() => holidays = zambianPublicHolidays(2026));

    bool has(int month, int day) => holidays.any((d) => d.month == month && d.day == day && d.year == 2026);

    test('fixed-date holidays are all present', () {
      expect(has(1, 1), isTrue, reason: "New Year's Day");
      expect(has(3, 8), isTrue, reason: "International Women's Day");
      expect(has(3, 12), isTrue, reason: 'Youth Day');
      expect(has(4, 28), isTrue, reason: "Kenneth Kaunda's Birthday");
      expect(has(5, 1), isTrue, reason: 'Labour Day');
      expect(has(5, 25), isTrue, reason: 'Africa Freedom Day');
      expect(has(10, 18), isTrue, reason: 'National Day of Prayer');
      expect(has(10, 24), isTrue, reason: 'Independence Day');
      expect(has(12, 25), isTrue, reason: 'Christmas Day');
    });

    test('the real, verified 2026 Easter weekend (Sunday = 5 April) is all 4 days', () {
      expect(has(4, 3), isTrue, reason: 'Good Friday');
      expect(has(4, 4), isTrue, reason: 'Holy Saturday');
      expect(has(4, 5), isTrue, reason: 'Easter Sunday');
      expect(has(4, 6), isTrue, reason: 'Easter Monday');
    });

    test("Heroes' Day is the first Monday in July, Unity Day is the very next day", () {
      final heroes = holidays.firstWhere((d) => d.month == 7 && d.weekday == DateTime.monday && d.day <= 7);
      expect(heroes.day, lessThanOrEqualTo(7));
      final unity = holidays.firstWhere((d) => d.month == 7 && d.day == heroes.day + 1);
      expect(unity.weekday, DateTime.tuesday);
    });

    test("Farmers' Day is the first Monday in August", () {
      final farmers = holidays.firstWhere((d) => d.month == 8 && d.day <= 7);
      expect(farmers.weekday, DateTime.monday);
    });

    test('a fixed holiday landing on a Sunday is also observed the following Monday', () {
      // Christmas Day 2033 is a Sunday - pick a year where a fixed date is
      // known to land on Sunday to check the observance rule fires.
      final holidays2033 = zambianPublicHolidays(2033);
      final christmas = DateTime(2033, 12, 25);
      expect(christmas.weekday, DateTime.sunday);
      expect(holidays2033.any((d) => d.year == 2033 && d.month == 12 && d.day == 25), isTrue);
      expect(holidays2033.any((d) => d.year == 2033 && d.month == 12 && d.day == 26), isTrue);
    });

    test('works algorithmically for a distant future year, not just hardcoded ones', () {
      final holidays2040 = zambianPublicHolidays(2040);
      expect(holidays2040.any((d) => d.month == 1 && d.day == 1), isTrue);
      expect(holidays2040.any((d) => d.month == 12 && d.day == 25), isTrue);
    });
  });
}
