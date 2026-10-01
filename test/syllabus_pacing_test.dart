import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';
import 'package:zambian_curriculum_app/models/zambian_term_calendar.dart';
import 'package:zambian_curriculum_app/services/syllabus_pacing.dart';

Competency _competency(int id) => Competency(id: id, sequenceNumber: 1, description: 'competency $id');

Topic _topic(int id, String name) => Topic(
      id: id,
      sequenceNumber: id,
      name: name,
      subTopics: const [],
      competencies: [_competency(id)],
      objectives: const [],
    );

/// Syllabus Inspection (owner request, 2026-09-29, redirected to a
/// zero-cost version) — guards the honest-approximation pacing math:
/// early in the year points near the start of the topic list, late in the
/// year points near the end, and it never throws on an empty syllabus.
void main() {
  final template = SyllabusTemplate(
    curriculum: const Curriculum(id: 1, code: 'X', name: 'X'),
    subject: const Subject(id: 1, curriculumId: 1, code: 'SUBJ', name: 'Subject'),
    grade: const Grade(id: 1, curriculumId: 1, code: 'G', name: 'Grade', level: 10),
    terms: [
      Term(id: 1, sequenceNumber: 1, name: 'Term 1', topics: [_topic(1, 'A'), _topic(2, 'B')]),
      Term(id: 2, sequenceNumber: 2, name: 'Term 2', topics: [_topic(3, 'C'), _topic(4, 'D')]),
      Term(id: 3, sequenceNumber: 3, name: 'Term 3', topics: [_topic(5, 'E')]),
    ],
  );

  test('before the school year starts: points at the very first entry', () {
    final result = syllabusPacingFor(template, now: DateTime(2026, 1, 1));
    expect(result.entries, hasLength(5));
    expect(result.approximateCurrentIndex, 0);
  });

  test('after the school year ends: points at the very last entry', () {
    final result = syllabusPacingFor(template, now: DateTime(2026, 12, 31));
    expect(result.approximateCurrentIndex, result.entries.length - 1);
  });

  test('midway through the year: lands somewhere in the middle, not at either end', () {
    final year = computeZambianSchoolYear(2026);
    final midpoint = year.term(2).open.add(const Duration(days: 20));
    final result = syllabusPacingFor(template, now: midpoint);
    expect(result.approximateCurrentIndex, greaterThan(0));
    expect(result.approximateCurrentIndex, lessThan(result.entries.length - 1));
  });

  test('an empty syllabus never throws — index is -1, entries is empty', () {
    final empty = SyllabusTemplate(
      curriculum: const Curriculum(id: 1, code: 'X', name: 'X'),
      subject: const Subject(id: 1, curriculumId: 1, code: 'SUBJ', name: 'Subject'),
      grade: const Grade(id: 1, curriculumId: 1, code: 'G', name: 'Grade', level: 10),
      terms: const [],
    );
    final result = syllabusPacingFor(empty, now: DateTime(2026, 6, 1));
    expect(result.entries, isEmpty);
    expect(result.approximateCurrentIndex, -1);
  });
}
