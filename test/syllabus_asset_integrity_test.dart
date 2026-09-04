// A real, permanent regression test (2026-09-04) for a class of bug that
// scheme_of_work_generation_test.dart's own JSON-only loading can't catch:
// the on-device SQLite ingestion path (TemplateRepository.ensureAllSeeded +
// DatabaseHelper.importTemplate/getSyllabus) reads a few fields these tests
// check directly against the asset files, and a bad value in either one
// silently drops a whole subject's topic tree — reported as "this subject
// is just blank when I open it", never a crash, never an error.
//
// Two real, confirmed cases, both found and fixed the same day:
//
// 1. Grade-code collisions: `grades` rows are looked up by
//    (curriculum_id, sequence_number) with no `code` tie-break, and two
//    different `grade.code` values meaning the same real grade/form (e.g.
//    history_form1.json said "F1" while every other CBC Form 1 subject
//    says "F1_CBC") produced two separate grade ROWS sharing one
//    sequence_number — the read-back query's un-ordered `.first` then
//    silently picked whichever row happened to be inserted first,
//    returning that ONE subject's topics for every other subject sharing
//    the form and nothing for the rest. Affected ~20 real CBC Form 1/2
//    subjects at once, all reported simply as "blank when clicked".
//
// 2. Missing `terms[].sequence_number`: the column is `NOT NULL`, and a
//    term missing that field throws mid-transaction — caught by
//    ensureAllSeeded's own per-file try/catch, which (correctly, for a
//    genuinely malformed OTHER file) skips just that one file, but that
//    means the file with the missing field imports NOTHING at all, not
//    just that one field. Found in 12 real bundled files.
//
// Also checks a third, narrower case found the same day: a manifest.json
// entry's subject_code/subject_name must match what the file's own
// internal `subject.code`/`subject.name` actually say — the DB is seeded
// from the file's own fields but looked up later by the manifest's fields,
// so a rename applied to only one side (exactly what happened when RE 2046
// was first split out from the generic "Religious Education" label) makes
// every subsequent lookup silently miss.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifestFile = File('assets/syllabi/manifest.json');
  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final templates = (manifest['templates'] as List).cast<Map<String, dynamic>>();

  Map<String, dynamic> loadFile(String file) =>
      jsonDecode(File('assets/syllabi/$file').readAsStringSync()) as Map<String, dynamic>;

  test('every term in every bundled syllabus file has an integer sequence_number', () {
    final failures = <String>[];
    for (final entry in templates) {
      final file = entry['file'] as String;
      final json = loadFile(file);
      final terms = (json['terms'] as List).cast<Map<String, dynamic>>();
      for (final term in terms) {
        if (term['sequence_number'] is! int) {
          failures.add('$file: term "${term['name']}" has sequence_number = ${term['sequence_number']}');
        }
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('every grade_level within one curriculum shares exactly one internal grade.code', () {
    // Mirrors DatabaseHelper.getSyllabus's grade lookup key: (curriculum
    // code, grade sequence_number). If two files disagree on grade.code
    // for the same real grade, they create two different `grades` rows
    // that the read-back query can't tell apart.
    final codeByCurriculumAndLevel = <String, Set<String>>{};
    for (final entry in templates) {
      final file = entry['file'] as String;
      final json = loadFile(file);
      final curriculumCode = (json['curriculum'] as Map<String, dynamic>)['code'] as String;
      final grade = json['grade'] as Map<String, dynamic>;
      final level = grade['level'];
      final code = grade['code'] as String;
      final key = '$curriculumCode|$level';
      codeByCurriculumAndLevel.putIfAbsent(key, () => {}).add(code);
      if (codeByCurriculumAndLevel[key]!.length > 1) {
        fail(
          '$file: grade level $level under $curriculumCode uses code "$code", but another already-checked file '
          'uses a different code for the same (curriculum, level): ${codeByCurriculumAndLevel[key]}. '
          'A real device silently loses one side\'s topics for this — see history_form1.json/'
          'civic_education_form2.json\'s 2026-09-04 fix for the exact same case.',
        );
      }
    }
  });

  test('every manifest entry\'s subject_code/subject_name matches its file\'s own internal subject fields', () {
    // The DB is seeded using the FILE's own subject.code/subject.name, but
    // looked up later using the MANIFEST's subject_code — a rename applied
    // to only one side (exactly what happened to RE 2046 on 2026-09-04)
    // makes every subsequent lookup silently return nothing.
    final failures = <String>[];
    for (final entry in templates) {
      final file = entry['file'] as String;
      final json = loadFile(file);
      final subject = json['subject'] as Map<String, dynamic>;
      if (subject['code'] != entry['subject_code']) {
        failures.add(
          '$file: manifest subject_code "${entry['subject_code']}" != internal subject.code "${subject['code']}"',
        );
      }
      if (subject['name'] != entry['subject_name']) {
        failures.add(
          '$file: manifest subject_name "${entry['subject_name']}" != internal subject.name "${subject['name']}"',
        );
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
