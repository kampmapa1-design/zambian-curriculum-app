import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/zambian_term_calendar.dart';
import 'package:zambian_curriculum_app/services/term_countdown.dart';

/// Learner-facing "Countdown Term?" (owner request, 2026-09-29) — reuses
/// the real Ministry term calendar already built for Scheme of Work; these
/// tests guard the date arithmetic, including the holiday edge cases a
/// naive "days until term.close" calculation would get wrong.
void main() {
  final term1 = computeZambianSchoolYear(2026).term(1);
  final term2 = computeZambianSchoolYear(2026).term(2);
  final term3 = computeZambianSchoolYear(2026).term(3);

  test('mid-term: counts down to the current term\'s own close date', () {
    final midway = term2.open.add(const Duration(days: 10));
    final result = currentTermCountdown(midway);
    expect(result.isCurrentlyInTerm, isTrue);
    expect(result.termNumber, 2);
    expect(result.year, 2026);
    expect(result.referenceDate, term2.close);
    expect(
      result.daysRemaining,
      daysUntilExcludingPublicHolidays(DateTime(midway.year, midway.month, midway.day), term2.close),
    );
  });

  test('a public holiday inside the remaining span is subtracted from the raw day count', () {
    // Independence Day (24 October) always falls inside Term 3 (opens
    // ~early September, closes ~early December) — a real, deterministic
    // case rather than picking an arbitrary date.
    final beforeIndependenceDay = DateTime(2026, 10, 20);
    final result = currentTermCountdown(beforeIndependenceDay);
    expect(result.isCurrentlyInTerm, isTrue);
    final rawDays = term3.close.difference(beforeIndependenceDay).inDays;
    expect(result.daysRemaining, lessThan(rawDays));
  });

  test('on the term\'s closing day itself: 0 days remaining, still "in term"', () {
    final result = currentTermCountdown(term1.close);
    expect(result.isCurrentlyInTerm, isTrue);
    expect(result.daysRemaining, 0);
  });

  test('on the term\'s opening day itself: full term remaining, "in term"', () {
    final result = currentTermCountdown(term1.open);
    expect(result.isCurrentlyInTerm, isTrue);
    expect(result.termNumber, 1);
  });

  test('in the gap between two terms: counts down to the NEXT term opening, not a negative number', () {
    final gapDay = term1.close.add(const Duration(days: 10));
    expect(gapDay.isBefore(term2.open), isTrue); // sanity: really is in the gap
    final result = currentTermCountdown(gapDay);
    expect(result.isCurrentlyInTerm, isFalse);
    expect(result.termNumber, 2);
    expect(result.referenceDate, term2.open);
    expect(result.daysRemaining, greaterThan(0));
  });

  test('before Term 1 opens (early January): counts down to Term 1\'s own opening', () {
    final beforeTerm1 = DateTime(2026, 1, 2);
    expect(beforeTerm1.isBefore(term1.open), isTrue);
    final result = currentTermCountdown(beforeTerm1);
    expect(result.isCurrentlyInTerm, isFalse);
    expect(result.termNumber, 1);
    expect(result.year, 2026);
    expect(result.referenceDate, term1.open);
  });

  test('the December break after Term 3 closes: rolls over to next year\'s Term 1', () {
    final decemberBreak = term3.close.add(const Duration(days: 5));
    expect(decemberBreak.year, 2026); // still December of the same year
    final result = currentTermCountdown(decemberBreak);
    expect(result.isCurrentlyInTerm, isFalse);
    expect(result.termNumber, 1);
    expect(result.year, 2027);
    expect(result.referenceDate, computeZambianSchoolYear(2027).term(1).open);
  });
}
