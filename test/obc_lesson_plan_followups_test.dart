// OBC lesson plan follow-ups (2026-09-27, Prompts 6-9):
//  6. Rationale: at least 2-3 points, not a single line.
//  7. Prior Knowledge / References / TLM auto-fill confirmed/restored.
//  8. 3 blank lines for sections 8, 9 and 10.
//  9. Teaching Notes auto-generated alongside the Lesson Plan, both OBC/CBC.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/lesson_plan.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/subject_content_item.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';
import 'package:zambian_curriculum_app/screens/lesson_plan_screen.dart';
import 'package:zambian_curriculum_app/services/database_helper.dart';
import 'package:zambian_curriculum_app/services/lesson_prior_knowledge.dart';
import 'package:zambian_curriculum_app/services/lesson_rationale.dart';
import 'package:zambian_curriculum_app/services/lesson_teaching_materials.dart';
import 'package:zambian_curriculum_app/services/obc_lesson_plan_docx.dart';
import 'package:zambian_curriculum_app/services/teaching_notes_document_service.dart';
import 'package:zambian_curriculum_app/services/teaching_notes_service.dart';
import 'package:zambian_curriculum_app/services/template_repository.dart';

import 'support/sqlite_test_setup.dart';

class _FakeNotesService extends TeachingNotesService {
  int generateCalls = 0;
  @override
  Future<bool> get isOnline async => true;
  @override
  Future<TeachingNotesResult> generate({
    required String topic,
    String? subtopic,
    required String subject,
    String? grade,
    required String syllabusContext,
    required String format,
    bool onePage = false,
    bool seniorSecondary = false,
  }) async {
    generateCalls++;
    return TeachingNotesResult(notes: '- A real bulletin point about $topic', topic: topic, subtopic: subtopic, format: format);
  }
}

class _FakeNotesDocumentService extends TeachingNotesDocumentService {
  int generateDocxCalls = 0;
  @override
  Future<File> generateDocx({required String title, required String notes}) async {
    generateDocxCalls++;
    final dir = Directory.systemTemp.createTempSync('fake_notes_');
    final file = File('${dir.path}/notes.docx')..writeAsStringSync(notes);
    return file;
  }
}

void main() {
  group('Prompt 6 — rationale has at least 2-3 points', () {
    test('a single real outcome alone is topped up from a sibling sub-topic to reach the minimum', () {
      final points = rationalePoints(['Describe the structure of a leaf'], topUp: ['Explain the process of transpiration']);
      expect(points.length, greaterThanOrEqualTo(kRationaleMinPoints));
      expect(points, hasLength(2));
      expect(points.first, 'Describe the structure of a leaf');
      expect(points[1], 'Explain the process of transpiration');
    });

    test('topUp is never touched when the real outcomes alone already reach the minimum', () {
      final points = rationalePoints(['Describe X', 'Explain Y'], topUp: ['Should never appear']);
      expect(points, ['Describe X', 'Explain Y']);
    });

    test('duplicate topUp candidates are skipped', () {
      final points = rationalePoints(['Describe X'], topUp: ['Describe X', 'Explain Y']);
      expect(points, ['Describe X', 'Explain Y']);
    });

    test('genuinely nothing to draw on (no outcomes, no topUp) stays as before: no fabricated points', () {
      expect(buildObcRationale(const []), isNull);
      expect(rationalePoints(const [], topUp: const []), isEmpty);
    });

    test('buildObcRationale text has at least 2 bullet lines when topUp is available', () {
      final text = buildObcRationale(['Describe cells'], topUp: ['Explain organelles'])!;
      expect(text.split('\n').where((l) => l.startsWith('•')), hasLength(2));
    });
  });

  group('Prompt 8 — evaluation/homework sections get 3 blank lines', () {
    test('template field definitions all say 3', () {
      for (final template in [defaultObcNaturalSciencesMathematicsLessonPlanTemplate, defaultObcSocialSciencesLessonPlanTemplate]) {
        // classExercise added 2026-09-28, alongside Homework's renumbering
        // from section 10 to 11 — see the matching comment on
        // _obcEvaluationSection in lesson_plan.dart.
        for (final id in ['teacherEvaluation', 'learnerEvaluation', 'classExercise', 'homework']) {
          final field = template.allFields.firstWhere((f) => f.id == id);
          expect(field.blankLines, 3, reason: '$id in ${template.name}');
        }
      }
    });

    test('a real generated document prints 3 ruled lines for each of sections 8, 9, 10 and 11 when left blank', () {
      final bytes = File(kObcLessonPlanTemplateAsset).readAsBytesSync();
      final draft = LessonPlanDraft.empty(defaultObcNaturalSciencesMathematicsLessonPlanTemplate).withValue('topic', 'X');
      final docx =
          buildObcLessonPlanDocx(templateBytes: bytes, template: defaultObcNaturalSciencesMathematicsLessonPlanTemplate, draft: draft);
      final archive = ZipDecoder().decodeBytes(docx);
      final xml = utf8.decode(archive.findFile('word/document.xml')!.content);
      final after8 = xml.substring(xml.indexOf('8. TEACHER'));
      final ruledLineCount = RegExp('_{80}').allMatches(after8).length;
      expect(ruledLineCount, 12, reason: '3 lines each for sections 8, 9, 10 and 11, none for the surrounding text');
    });
  });

  group('Prompt 7 — Prior Knowledge / References / TLM', () {
    late TemplateRepository repo;

    setUpAll(() async {
      await setUpTestDatabase();
      repo = TemplateRepository(databaseHelper: DatabaseHelper.instance);
      await repo.ensureAllSeeded();
    });

    test('findPrecedingSyllabusEntry: the real Biology Grade 10 sub-topic that comes right before this one', () async {
      final template = await repo.loadSyllabus(curriculumCode: 'OBC_2013', subjectCode: 'BIO', gradeLevel: 10);
      final entries = allSchemeOfWorkEntries(template!);
      expect(entries.length, greaterThan(5));
      final current = entries[3];

      final preceding = await findPrecedingSyllabusEntry(
        templates: repo,
        curriculumCode: 'OBC_2013',
        subjectCode: 'BIO',
        gradeLevel: 10,
        current: current,
      );

      expect(preceding, isNotNull);
      expect(preceding!.topic.id, entries[2].topic.id);
      expect(preceding.subTopic?.id, entries[2].subTopic?.id);
    });

    test('the syllabus\'s very first entry has nothing preceding it', () async {
      final template = await repo.loadSyllabus(curriculumCode: 'OBC_2013', subjectCode: 'BIO', gradeLevel: 10);
      final entries = allSchemeOfWorkEntries(template!);
      final preceding = await findPrecedingSyllabusEntry(
        templates: repo,
        curriculumCode: 'OBC_2013',
        subjectCode: 'BIO',
        gradeLevel: 10,
        current: entries.first,
      );
      expect(preceding, isNull);
    });

    test('an unknown subject/grade combination resolves to null rather than throwing', () async {
      final template = await repo.loadSyllabus(curriculumCode: 'OBC_2013', subjectCode: 'BIO', gradeLevel: 10);
      final anyEntry = allSchemeOfWorkEntries(template!).first;
      final preceding = await findPrecedingSyllabusEntry(
        templates: repo,
        curriculumCode: 'OBC_2013',
        subjectCode: 'NOPE',
        gradeLevel: 99,
        current: anyEntry,
      );
      expect(preceding, isNull);
    });

    test('buildPriorKnowledgeText grounds the text in the real preceding sub-topic\'s own outcomes', () async {
      final template = await repo.loadSyllabus(curriculumCode: 'OBC_2013', subjectCode: 'BIO', gradeLevel: 10);
      final entries = allSchemeOfWorkEntries(template!);
      final preceding = entries[2];
      final text = buildPriorKnowledgeText(preceding);
      expect(text, isNotNull);
      expect(text, contains(preceding.title));
      expect(text, contains(outcomesOf(preceding).first));
    });

    test('buildPriorKnowledgeText is null with nothing to ground it in', () {
      expect(buildPriorKnowledgeText(null), isNull);
    });

    test('never mentions more than 2 points, even when the preceding sub-topic has more outcomes', () async {
      final template = await repo.loadSyllabus(curriculumCode: 'OBC_2013', subjectCode: 'BIO', gradeLevel: 10);
      final entries = allSchemeOfWorkEntries(template!);
      final preceding = entries.firstWhere((e) => outcomesOf(e).length > 2, orElse: () => entries[2]);
      final outcomes = outcomesOf(preceding);
      final text = buildPriorKnowledgeText(preceding)!;
      final bulletCount = '•'.allMatches(text).length;
      expect(bulletCount, lessThanOrEqualTo(2));
      if (outcomes.length > 2) expect(text, isNot(contains(outcomes[2])));
    });
  });

  group('Prompt 7 — Teaching and Learning Materials/Resources', () {
    test('always includes the standard classroom staples', () {
      expect(buildTeachingMaterialsText(const []), 'Chalkboard, Textbook, Exercise books');
    });

    test('tops up with real bundled material titles, never duplicating', () {
      final items = [
        SubjectContentItem(
          title: 'Biology Teaching Module',
          subjectName: 'Biology',
          resourceType: 'teachingModule',
          sourceUrl: 'bundled://x',
          fileName: 'x.txt',
          downloadedAt: DateTime(2026, 1, 1),
          sizeBytes: 1000,
        ),
      ];
      final text = buildTeachingMaterialsText(items);
      expect(text, 'Biology Teaching Module, Chalkboard, Textbook, Exercise books');
    });

    test('a syllabus placeholder replaces real material titles entirely (real bug: a Form 1 module title '
        'was being cited as a reference for a Grade 10 lesson)', () {
      final items = [
        SubjectContentItem(
          title: 'Form 1 Biology Teaching Module',
          subjectName: 'Biology',
          resourceType: 'teachingModule',
          sourceUrl: 'bundled://x',
          fileName: 'x.txt',
          downloadedAt: DateTime(2026, 1, 1),
          sizeBytes: 1000,
        ),
      ];
      final text = buildTeachingMaterialsText(items, syllabusPlaceholder: 'Biology Grade 10-12 Syllabus');
      expect(text, 'Biology Grade 10-12 Syllabus, Chalkboard, Textbook, Exercise books');
      expect(text, isNot(contains('Form')));
    });
  });

  group('Prompt 9 — generating a Lesson Plan also auto-generates Teaching Notes, both OBC and CBC', () {
    Future<_FakeNotesService> tapExportAndReturnFakes(WidgetTester tester, LessonPlanTemplate template) async {
      final fakeNotes = _FakeNotesService();
      final fakeNotesDoc = _FakeNotesDocumentService();
      await tester.binding.setSurfaceSize(const Size(800, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const topic = Topic(id: 1, sequenceNumber: 1, name: 'A Topic', subTopics: [], objectives: [], competencies: []);
      const entry = SchemeOfWorkEntry(weekNumber: 1, topic: topic, objectives: [], competencies: []);
      await tester.pumpWidget(MaterialApp(
        home: LessonPlanScreen(
          subjectName: 'Biology',
          curriculumCode: template.usesOfficialObcLayout ? 'OBC_2013' : 'CBC_2023',
          subjectCode: 'BIO',
          gradeLevel: 10,
          entry: entry,
          template: template,
          notesService: fakeNotes,
          notesDocumentService: fakeNotesDoc,
          isOneOff: true,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Export & Share (Word)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(fakeNotesDoc.generateDocxCalls, 1, reason: 'Teaching Notes must be generated in the same action, no second step');
      return fakeNotes;
    }

    testWidgets('OBC template: exporting the lesson plan also generates the companion Teaching Notes', (tester) async {
      await tapExportAndReturnFakes(tester, defaultObcNaturalSciencesMathematicsLessonPlanTemplate);
    });

    testWidgets('CBC template: exporting the lesson plan also generates the companion Teaching Notes', (tester) async {
      await tapExportAndReturnFakes(tester, defaultCbcLessonPlanTemplate);
    });

    testWidgets('the caption confirming automatic Notes generation is always visible, not just after export', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const topic = Topic(id: 1, sequenceNumber: 1, name: 'A Topic', subTopics: [], objectives: [], competencies: []);
      const entry = SchemeOfWorkEntry(weekNumber: 1, topic: topic, objectives: [], competencies: []);
      await tester.pumpWidget(const MaterialApp(
        home: LessonPlanScreen(
          subjectName: 'Biology',
          curriculumCode: 'CBC_2023',
          subjectCode: 'BIO',
          gradeLevel: 10,
          entry: entry,
          isOneOff: true,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('companion Lesson Notes'), findsOneWidget);
    });
  });
}
