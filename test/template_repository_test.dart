// Real SQLite + real bundled-asset coverage (2026-09-15) for
// TemplateRepository. `flutter test` serves the real files declared under
// `assets:` in pubspec.yaml through rootBundle once
// TestWidgetsFlutterBinding is initialized (done by setUpTestDatabase), so
// this exercises the actual manifest.json and syllabus JSON files, not
// stand-ins.
//
// TemplateRepository.ensureAllSeeded's "already seeded" guard
// (_seededThisProcess) is a STATIC flag with no reset hook — real, by
// design (see its own doc comment: it must survive across every
// TemplateRepository instance a screen creates, for the life of the app
// process). That means it also survives across every `test()` in this
// *process*, so seeding happens exactly ONCE, in setUpAll, and no test
// below wipes the database afterwards — these tests only ever read.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/database_helper.dart';
import 'package:zambian_curriculum_app/services/template_repository.dart';

import 'support/sqlite_test_setup.dart';

void main() {
  late TemplateRepository repo;

  setUpAll(() async {
    await setUpTestDatabase();
    repo = TemplateRepository(databaseHelper: DatabaseHelper.instance);
    await repo.ensureAllSeeded();
  });

  test('loadManifest lists every bundled curriculum/subject/grade combination', () async {
    final manifest = await repo.loadManifest();
    expect(manifest, isNotEmpty);
    expect(manifest.any((e) => e.file == 'history_form1.json'), isTrue);
  });

  test('ensureAllSeeded imports the bundled templates into local storage', () async {
    final curricula = await repo.listCurricula();
    expect(curricula, isNotEmpty);
    expect(curricula.any((c) => c.code == 'CBC_2023'), isTrue);
  });

  test('loadSyllabus returns a real bundled subject/grade after seeding', () async {
    final template = await repo.loadSyllabus(curriculumCode: 'CBC_2023', subjectCode: 'HIST', gradeLevel: 1);
    expect(template, isNotNull);
    expect(template!.subject.code, 'HIST');
    expect(template.grade.level, 1);
    expect(template.terms, isNotEmpty);
  });

  test('loadSyllabus caches — a second call for the same key is the identical instance', () async {
    final first = await repo.loadSyllabus(curriculumCode: 'CBC_2023', subjectCode: 'HIST', gradeLevel: 1);
    final second = await repo.loadSyllabus(curriculumCode: 'CBC_2023', subjectCode: 'HIST', gradeLevel: 1);
    expect(identical(first, second), isTrue);
  });

  test('loadSyllabus returns null for a combination that was never bundled/imported', () async {
    final template =
        await repo.loadSyllabus(curriculumCode: 'CBC_2023', subjectCode: 'DOES_NOT_EXIST', gradeLevel: 1);
    expect(template, isNull);
  });

  test('hasRealSource is true for a bundled file that discloses a real source', () async {
    expect(await repo.hasRealSource('history_form1.json'), isTrue);
  });

  test('hasRealSource is false for the bundled placeholder file, which has no _source field', () async {
    expect(await repo.hasRealSource('obc2013_english_form3_placeholder.json'), isFalse);
  });

  test('hasRealSource falls back to false for a file that cannot be found at all', () async {
    expect(await repo.hasRealSource('does_not_exist_anywhere.json'), isFalse);
  });

  test('importUserSuppliedTemplate imports a runtime-supplied template outside the bundled assets', () async {
    await repo.importUserSuppliedTemplate({
      'curriculum': {'code': 'USER_SUPPLIED', 'name': 'User Supplied Curriculum', 'description': null},
      'subject': {'code': 'USR', 'name': 'User Subject', 'description': null},
      'grade': {'code': 'G7', 'name': 'Grade 7', 'level': 7, 'phase': null},
      'terms': [
        {
          'code': 'T1',
          'name': 'Term 1',
          'sequence_number': 1,
          'topics': [
            {
              'name': 'Imported Topic',
              'sequence_number': 1,
              'learning_objectives': <Map<String, dynamic>>[],
              'competencies': <Map<String, dynamic>>[],
              'sub_topics': <Map<String, dynamic>>[],
            },
          ],
        },
      ],
    });

    final template = await repo.loadSyllabus(curriculumCode: 'USER_SUPPLIED', subjectCode: 'USR', gradeLevel: 7);
    expect(template, isNotNull);
    expect(template!.terms.single.topics.single.name, 'Imported Topic');
  });
}
