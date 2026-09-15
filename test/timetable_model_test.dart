import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/timetable.dart';

/// Timetable Generation — real regression coverage for the model
/// parsing layer (the deterministic scheduling engine itself was already
/// verified separately against synthetic data; this covers the Dart-side
/// Firestore document parsing, which had no automated test).
void main() {
  group('TimetableConfig.fromMap', () {
    test('an empty document falls back to TimetableConfig.empty()\'s own defaults', () {
      final config = TimetableConfig.fromMap({});
      final defaults = TimetableConfig.empty();
      expect(config.periodsPerDay, defaults.periodsPerDay);
      expect(config.periodLengthMinutes, defaults.periodLengthMinutes);
      expect(config.teachingDaysPerWeek, defaults.teachingDaysPerWeek);
      expect(config.practicalSubjectsExceptionList, defaults.practicalSubjectsExceptionList);
    });

    test('maxDailyPeriodsPerTeacher falls back to periodsPerDay when absent (pre-Stage-4 documents)', () {
      final config = TimetableConfig.fromMap({'periodsPerDay': 9});
      expect(config.maxDailyPeriodsPerTeacher, 9);
    });

    test('a fully populated document parses every field correctly', () {
      final config = TimetableConfig.fromMap({
        'periodsPerDay': 8,
        'periodLengthMinutes': 35,
        'teachingDaysPerWeek': 5,
        'subjectDefaults': {'Mathematics': 6},
        'practicalSubjectsExceptionList': ['Food & Nutrition'],
        'maxDailyPeriodsPerTeacher': 6,
      });
      expect(config.subjectDefaults['Mathematics'], 6);
      expect(config.practicalSubjectsExceptionList, ['Food & Nutrition']);
      expect(config.maxDailyPeriodsPerTeacher, 6);
    });
  });

  group('TimetableAssignment', () {
    test('locked defaults to false when absent (every assignment before Stage 7 existed)', () {
      final assignment = TimetableAssignment.fromMap({
        'classId': 'c1',
        'className': 'Grade 8A',
        'subjectName': 'Mathematics',
        'teacherUid': 'uid1',
        'day': 0,
        'period': 0,
      });
      expect(assignment.locked, isFalse);
    });

    test('locked: true survives parsing', () {
      final assignment = TimetableAssignment.fromMap({'classId': 'c1', 'locked': true});
      expect(assignment.locked, isTrue);
    });
  });

  group('GeneratedTimetable.fromMap', () {
    test('an empty document parses to three empty lists, never throws', () {
      final generated = GeneratedTimetable.fromMap({});
      expect(generated.assignments, isEmpty);
      expect(generated.conflicts, isEmpty);
      expect(generated.conflictExplanations, isEmpty);
    });

    test('conflictExplanations parses independently of assignments/conflicts (Stage 6 written later than Stage 4)', () {
      final generated = GeneratedTimetable.fromMap({
        'assignments': [
          {'classId': 'c1', 'className': 'Grade 8A', 'subjectName': 'Mathematics', 'teacherUid': 'uid1', 'day': 0, 'period': 0},
        ],
        'conflicts': [
          {'description': 'No teacher assigned'},
        ],
        'conflictExplanations': [
          {'conflictIndex': 0, 'explanation': 'Because...', 'suggestedFix': 'Assign a teacher.'},
        ],
      });
      expect(generated.assignments, hasLength(1));
      expect(generated.conflicts, hasLength(1));
      expect(generated.conflictExplanations, hasLength(1));
      expect(generated.conflictExplanations.single.conflictIndex, 0);
    });
  });

  group('ParsedTimetableConstraint.fromMap', () {
    test('defaults kind to unrecognized and every list field to empty when the document is empty', () {
      final parsed = ParsedTimetableConstraint.fromMap({});
      expect(parsed.kind, 'unrecognized');
      expect(parsed.daysOfWeek, isEmpty);
      expect(parsed.unavailableSlots, isEmpty);
      expect(parsed.teacherUid, isNull);
    });
  });
}
