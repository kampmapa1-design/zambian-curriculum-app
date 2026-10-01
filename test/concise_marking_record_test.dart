import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/concise_marking_record.dart';
import 'package:zambian_curriculum_app/models/marking_rubric.dart';

/// Marking Reliability Stage 10 depends on the ORIGINAL rubric a script was
/// scored with surviving a save/reload — otherwise a later mark correction
/// can only guess at, or silently drop, the section rules that produced the
/// original score. These guard that.
void main() {
  test('a record with a rubric survives a JSON round-trip intact', () {
    const rubric = MarkingRubric(
      sections: [
        RubricSection(name: 'Section A', questionsToAnswer: null, marksAllocated: 40),
        RubricSection(name: 'Section B', questionsToAnswer: 2, marksAllocated: 60),
      ],
      paperTotalMarks: 100,
      instructionsSummary: 'Answer all of A, any two of B.',
    );
    final record = ConciseMarkingRecord(
      markedAt: DateTime(2026, 9, 22),
      engine: 'concise',
      annotations: const [ScriptAnnotationRecord(questionLabel: '1', pageIndex: 0, yMin: 1, xMin: 1, yMax: 2, xMax: 2)],
      scoreJson: const {'awardedMarks': 80.0, 'possibleMarks': 100.0},
      sectionByLabel: const {'1': 'Section A'},
      rubric: rubric,
    );

    final restored = ConciseMarkingRecord.fromJson(record.toJson());
    expect(restored.rubric, isNotNull);
    expect(restored.rubric!.sections.map((s) => s.name), ['Section A', 'Section B']);
    expect(restored.rubric!.sections[1].questionsToAnswer, 2);
    expect(restored.rubric!.paperTotalMarks, 100);
    expect(restored.rubric!.instructionsSummary, 'Answer all of A, any two of B.');
  });

  test('a record with NO rubric (no section structure, or saved before this field existed) round-trips as null, not an error', () {
    final record = ConciseMarkingRecord(
      markedAt: DateTime(2026, 9, 22),
      engine: 'stable',
      annotations: const [],
      scoreJson: const {},
    );
    expect(record.toJson().containsKey('rubric'), isFalse, reason: 'no null literal written for an old/plain-sum record');

    final restored = ConciseMarkingRecord.fromJson(record.toJson());
    expect(restored.rubric, isNull);
  });

  test('loading an OLD saved record (no "rubric" key at all, as every record before 2026-09-22 looks) does not crash', () {
    final old = ConciseMarkingRecord.fromJson({
      'markedAt': '2026-09-01T00:00:00.000',
      'engine': 'concise',
      'annotations': <Map<String, dynamic>>[],
      'score': <String, dynamic>{'awardedMarks': 5.0, 'possibleMarks': 10.0},
      'sectionByLabel': <String, dynamic>{},
      // no 'rubric' key — exactly what a pre-Stage-10 saved record looks like
    });
    expect(old.rubric, isNull);
  });
}
