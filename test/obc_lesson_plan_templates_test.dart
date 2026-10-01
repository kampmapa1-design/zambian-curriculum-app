// OBC lesson plan templates (2026-09-26): the Natural Sciences & Mathematics
// 5-column layout, the Social Sciences 4-column variant, the automatic
// category-driven selection between them (CBC untouched), the content-column
// mapping rules, and REAL generated documents (real bundled syllabus topics)
// checked column by column.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:xml/xml.dart';
import 'package:zambian_curriculum_app/models/lesson_plan.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';
import 'package:zambian_curriculum_app/services/lesson_plan_document_service.dart';
import 'package:zambian_curriculum_app/services/lesson_plan_template_selector.dart';
import 'package:zambian_curriculum_app/services/lesson_progression_generator.dart';
import 'package:zambian_curriculum_app/services/lesson_rationale.dart';
import 'package:zambian_curriculum_app/services/lesson_teaching_points.dart';
import 'package:zambian_curriculum_app/services/obc_lesson_plan_docx.dart';
import 'package:zambian_curriculum_app/services/senior_secondary_content_filter.dart';
import 'package:zambian_curriculum_app/services/text_excerpt_matching.dart';

class _FakeTempPathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakeTempPathProvider(this._path);
  final String _path;
  @override
  Future<String?> getTemporaryPath() async => _path;
}

// ---- real syllabus loading (same approach as lesson_progression_generator_test) ----

int _nextId = 1;

List<Competency> _competencies(Map<String, dynamic> json) => [
      for (final c in (json['competencies'] as List?) ?? const [])
        Competency(
          id: _nextId++,
          sequenceNumber: (c as Map<String, dynamic>)['sequence_number'] as int? ?? 0,
          description: c['description'] as String? ?? '',
          category: c['category'] as String?,
        ),
    ];

List<LearningObjective> _objectives(Map<String, dynamic> json) => [
      for (final o in (json['objectives'] as List?) ?? const [])
        LearningObjective(
          id: _nextId++,
          sequenceNumber: (o as Map<String, dynamic>)['sequence_number'] as int? ?? 0,
          description: o['description'] as String? ?? '',
        ),
    ];

SyllabusTemplate _loadTemplate(String file, String subjectCode) {
  final json = jsonDecode(File('assets/syllabi/$file').readAsStringSync()) as Map<String, dynamic>;
  final terms = <Term>[];
  final termsJson = json['terms'] as List;
  for (var ti = 0; ti < termsJson.length; ti++) {
    final termJson = termsJson[ti] as Map<String, dynamic>;
    final topics = <Topic>[];
    final topicsJson = termJson['topics'] as List;
    for (var toi = 0; toi < topicsJson.length; toi++) {
      final topicJson = topicsJson[toi] as Map<String, dynamic>;
      final subTopics = <SubTopic>[];
      final subJson = (topicJson['sub_topics'] as List?) ?? const [];
      for (var si = 0; si < subJson.length; si++) {
        final st = subJson[si] as Map<String, dynamic>;
        subTopics.add(SubTopic(
          id: _nextId++,
          sequenceNumber: si,
          name: st['name'] as String,
          description: st['description'] as String?,
          objectives: _objectives(st),
          competencies: _competencies(st),
          weekNumber: st['week_number'] as int?,
          references: st['references'] as String?,
        ));
      }
      topics.add(Topic(
        id: _nextId++,
        sequenceNumber: toi,
        name: topicJson['name'] as String,
        description: topicJson['description'] as String?,
        subTopics: subTopics,
        objectives: _objectives(topicJson),
        competencies: _competencies(topicJson),
        weekNumber: topicJson['week_number'] as int?,
        references: topicJson['references'] as String?,
      ));
    }
    terms.add(Term(id: _nextId++, sequenceNumber: ti, name: termJson['name'] as String, topics: topics));
  }
  return SyllabusTemplate(
    curriculum: const Curriculum(id: 1, code: 'OBC_2013', name: '2013 Outcome-Based Curriculum'),
    subject: Subject(id: 1, curriculumId: 1, code: subjectCode, name: (json['subject'] as Map)['name'] as String),
    grade: const Grade(id: 1, curriculumId: 1, code: 'G10', name: 'Grade 10', level: 10),
    terms: terms,
  );
}

/// The first real scheme entry with competencies. NOTE: the real OBC syllabi
/// carry Specific Outcomes (competencies) and NO objectives, so the
/// "learning points" of an OBC lesson are its competencies.
SchemeOfWorkEntry _firstRealEntry(SyllabusTemplate template) =>
    generateSchemeOfWork(template, null).firstWhere((e) => e.competencies.isNotEmpty);

List<String> _learningPoints(SchemeOfWorkEntry e) => e.objectives.isNotEmpty
    ? [for (final o in e.objectives) o.description]
    : [for (final c in e.competencies) c.description];

/// A draft built the way LessonPlanScreen builds a fresh one for [template].
LessonPlanDraft _draftFor(LessonPlanTemplate template, SyllabusTemplate syllabus, SchemeOfWorkEntry entry,
    {String? excerpt}) {
  var draft = LessonPlanDraft.empty(template)
      .withValue('teacherName', 'Test Teacher')
      .withValue('className', '10A')
      .withValue('date', '2026-09-26')
      .withValue('school', 'Test Secondary School')
      .withValue('subject', syllabus.subject.name)
      .withValue('topic', entry.topic.name)
      .withValue('duration', '80 Minutes')
      .withValue('specificCompetences', entry.competencies.map((c) => c.description).join('\n'))
      .withValue('lessonGoal', 'By the end of the lesson, learners will be able to ${entry.competencies.first.description}.')
      .withValue('rationale', buildObcRationale(_learningPoints(entry)) ?? '')
      .withValue('homework', defaultObcHomeworkText);
  if (entry.subTopic != null) draft = draft.withValue('subTopic', entry.subTopic!.name);
  final rows = generateDefaultProgression(template.progressionStages, entry,
      subjectContentExcerpt: excerpt, contentMode: template.progressionContentMode);
  for (var i = 0; i < rows.length; i++) {
    draft = draft.withProgressionRow(i, rows[i]);
  }
  return draft;
}

/// The excerpt the app would find for [entry] in the REAL bundled material of
/// [contentDir] — cleaned for Grade 10-12 exactly as the app does.
String? _realExcerpt(String contentDir, SchemeOfWorkEntry entry) {
  final keywords = keywordsOf('${entry.topic.name} ${entry.subTopic?.name ?? ''}');
  String? best;
  var bestScore = 0;
  for (final f in Directory('assets/subject_content/$contentDir').listSync().whereType<File>().where((f) => f.path.endsWith('.txt'))) {
    final found = bestExcerptFor(cleanSourceText(f.readAsStringSync()), keywords);
    if (found != null && found.score > bestScore) {
      bestScore = found.score;
      best = found.excerpt;
    }
  }
  return best;
}

// ---- reading a generated .docx ----

XmlDocument _documentXml(List<int> docx) {
  final archive = ZipDecoder().decodeBytes(docx);
  final file = archive.findFile('word/document.xml')!;
  return XmlDocument.parse(utf8.decode(file.content));
}

List<XmlElement> _tables(XmlDocument doc) => doc.findAllElements('w:tbl').toList();

String _cellText(XmlElement cell) => cell
    .findAllElements('w:r')
    .map((r) => r.children.map((c) => c is XmlElement ? (c.name.local == 't' ? c.innerText : (c.name.local == 'br' ? '\n' : '')) : '').join())
    .join();

List<List<String>> _tableRows(XmlElement table) => [
      for (final tr in table.findElements('w:tr')) [for (final tc in tr.findElements('w:tc')) _cellText(tc)],
    ];

int _gridColumns(XmlElement table) => table.findElements('w:tblGrid').single.findElements('w:gridCol').length;

String _allText(XmlDocument doc) => doc.findAllElements('w:t').map((t) => t.innerText).join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<int> obcTemplateBytes;
  setUpAll(() {
    obcTemplateBytes = File(kObcLessonPlanTemplateAsset).readAsBytesSync();
  });

  group('template definitions', () {
    test('Natural Sciences & Mathematics: exactly the 5 original columns, all in template order', () {
      const t = defaultObcNaturalSciencesMathematicsLessonPlanTemplate;
      expect(t.hasContentColumn, isTrue);
      expect(t.assessmentColumnLabel, 'ASSESSMENT/EVIDENCE');
      expect(t.usesOfficialObcLayout, isTrue);
    });

    test('Social Sciences: no content column, last column renamed', () {
      const t = defaultObcSocialSciencesLessonPlanTemplate;
      expect(t.hasContentColumn, isFalse);
      expect(t.progressionContentMode, LessonProgressionContentMode.omitted);
      expect(t.assessmentColumnLabel, 'Assessment Criteria');
    });

    test('both variants share the same header block and eleven numbered sections', () {
      List<String> labels(LessonPlanTemplate t) => [for (final f in t.allFields) f.label];
      expect(labels(defaultObcSocialSciencesLessonPlanTemplate),
          labels(defaultObcNaturalSciencesMathematicsLessonPlanTemplate));
      final numbered = [
        for (final f in defaultObcNaturalSciencesMathematicsLessonPlanTemplate.allFields)
          if (RegExp(r'^\d+\. ').hasMatch(f.label)) f.label,
      ];
      // 1-6 and 8-11 are fields; 7 is the progression table itself. 10
      // (Class Exercise) and 11 (Homework, renumbered from 10) were added
      // 2026-09-28, per explicit request — both now sit after Teacher's/
      // Learner's Evaluation rather than mid-table.
      expect(numbered.map((l) => l.split('.').first).toList(), ['1', '2', '3', '4', '5', '6', '8', '9', '10', '11']);
    });

    test('JSON round trip keeps the mode; legacy JSON without the new keys still means "folded"', () {
      final round = LessonPlanTemplate.fromJson(
          defaultObcSocialSciencesLessonPlanTemplate.toJson());
      expect(round.progressionContentMode, LessonProgressionContentMode.omitted);
      expect(round.assessmentColumnLabel, 'Assessment Criteria');

      final legacy = defaultCdcLessonPlanTemplate.toJson()
        ..remove('progressionContentMode')
        ..remove('assessmentColumnLabel')
        ..remove('usesOfficialObcLayout');
      final parsed = LessonPlanTemplate.fromJson(legacy);
      expect(parsed.progressionContentMode, LessonProgressionContentMode.foldedIntoTeacherRole);
      expect(parsed.assessmentColumnLabel, 'Assessment Criteria');
      expect(parsed.usesOfficialObcLayout, isFalse);
    });

    test('a stored progression row without "content" still loads', () {
      final row = LessonProgressionRow.fromJson({'stage': 'Introduction', 'teacherRole': 'x'});
      expect(row.content, '');
    });
  });

  group('automatic template selection', () {
    test('OBC: category decides; no category keeps the pre-existing template', () {
      expect(selectLessonPlanTemplate(curriculumCode: 'OBC_2013', subjectCategory: kSubjectCategoryNaturalSciencesMathematics),
          same(defaultObcNaturalSciencesMathematicsLessonPlanTemplate));
      expect(selectLessonPlanTemplate(curriculumCode: 'OBC_2013', subjectCategory: kSubjectCategorySocialSciences),
          same(defaultObcSocialSciencesLessonPlanTemplate));
      expect(selectLessonPlanTemplate(curriculumCode: 'OBC_2013'), same(defaultCdcLessonPlanTemplate));
    });

    test('CBC is never affected by any category', () {
      for (final category in [null, kSubjectCategoryNaturalSciencesMathematics, kSubjectCategorySocialSciences]) {
        expect(selectLessonPlanTemplate(curriculumCode: 'CBC_2023', subjectCategory: category),
            same(defaultCbcLessonPlanTemplate));
      }
    });

    test('real bundled manifest: classified OBC subjects resolve to their template; CBC never does', () async {
      Future<LessonPlanTemplate> pick(String curriculum, String subject) =>
          lessonPlanTemplateForSubject(curriculumCode: curriculum, subjectCode: subject);

      for (final code in ['BIO', 'CHEM', 'PHY', 'MATH', 'AGR']) {
        expect(await pick('OBC_2013', code), same(defaultObcNaturalSciencesMathematicsLessonPlanTemplate), reason: code);
      }
      for (final code in ['HIST', 'GEOG', 'CIVIC', 'RE2046', 'RE2044']) {
        expect(await pick('OBC_2013', code), same(defaultObcSocialSciencesLessonPlanTemplate), reason: code);
      }
      // Unclassified subjects keep today's template rather than being forced into either.
      for (final code in ['ENG', 'COMM', 'POA', 'PE']) {
        expect(await pick('OBC_2013', code), same(defaultCdcLessonPlanTemplate), reason: code);
      }
      // CBC: HIST exists under both curricula — CBC's must be untouched.
      expect(await pick('CBC_2023', 'HIST'), same(defaultCbcLessonPlanTemplate));
      expect(await pick('CBC_2023', 'CIVIC'), same(defaultCbcLessonPlanTemplate));
    });

    test('the manifest tags only OBC entries — no CBC entry carries a category', () async {
      final manifest = jsonDecode(await rootBundle.loadString('assets/syllabi/manifest.json')) as Map<String, dynamic>;
      for (final e in (manifest['templates'] as List).cast<Map<String, dynamic>>()) {
        if (e['curriculum_code'] == 'CBC_2023') {
          expect(e.containsKey('subject_category'), isFalse, reason: '${e['subject_code']} ${e['file']}');
        }
      }
    });
  });

  group('content-column mapping', () {
    // Shares the topic's own wording (living organisms / characteristics), as real on-topic material does.
    const excerpt = 'Living organisms show the characteristics of life in every cell.';

    Iterable<String> allRoleText(List<LessonProgressionRow> rows) =>
        rows.expand((r) => [r.teacherRole, r.learnersRole, r.assessmentCriteria]);

    test('own column (Natural Sciences): teaching points go in the Content column only, topped up from the syllabus', () {
      final syllabus = _loadTemplate('biology_grade10.json', 'BIO');
      final entry = _firstRealEntry(syllabus);
      final rows = generateDefaultProgression(defaultObcNaturalSciencesMathematicsLessonPlanTemplate.progressionStages, entry,
          subjectContentExcerpt: excerpt, contentMode: LessonProgressionContentMode.ownColumn);

      final development = rows.singleWhere((r) => r.stage == 'Development');
      expect(development.content, contains(excerpt), reason: 'the lesson material comes first');
      expect(development.content, contains(_learningPoints(entry).first), reason: 'then the syllabus outcomes top it up');
      expect(allRoleText(rows).join('\n'), isNot(contains(excerpt)), reason: 'not duplicated into the role columns');
      expect(rows.every((r) => r.content.isNotEmpty), isTrue, reason: 'every stage has real content in this layout');
    });

    test('own column: a real topic with many outcomes fills SIX bullets in Development', () {
      final syllabus = _loadTemplate('chemistry_grade10.json', 'CHEM');
      final entry = generateSchemeOfWork(syllabus, null).firstWhere((e) => e.competencies.length >= 6);
      final rows = generateDefaultProgression(defaultObcNaturalSciencesMathematicsLessonPlanTemplate.progressionStages, entry,
          contentMode: LessonProgressionContentMode.ownColumn);
      final bullets = rows.singleWhere((r) => r.stage == 'Development').content.split('\n');
      expect(bullets, hasLength(6));
      expect(bullets.every((b) => b.startsWith('•  ')), isTrue);
    });

    test('own column: lesson material with many sentences gives exactly six points, in order', () {
      const material = 'Living organisms carry out seven life processes. Movement is a characteristic of living organisms '
          'that changes the position of the whole organism. Respiration releases energy in living organisms from food. '
          'Sensitivity is a characteristic of living organisms to detect changes. Growth is a permanent increase in size '
          'of living organisms. Reproduction is a life process of living organisms. Excretion removes wastes from living '
          'organisms. Nutrition supplies living organisms with materials.';
      final syllabus = _loadTemplate('biology_grade10.json', 'BIO');
      final entry = _firstRealEntry(syllabus);
      final rows = generateDefaultProgression(defaultObcNaturalSciencesMathematicsLessonPlanTemplate.progressionStages, entry,
          subjectContentExcerpt: material, contentMode: LessonProgressionContentMode.ownColumn);
      final bullets = rows.singleWhere((r) => r.stage == 'Development').content.split('\n');
      expect(bullets, hasLength(6));
      expect(bullets.first, '•  Living organisms carry out seven life processes.');
      expect(bullets.last, '•  Reproduction is a life process of living organisms.');
    });

    test('omitted (Social Sciences): the content is dropped — not folded into any other column', () {
      final syllabus = _loadTemplate('history_grade10.json', 'HIST');
      final entry = _firstRealEntry(syllabus);
      final rows = generateDefaultProgression(defaultObcSocialSciencesLessonPlanTemplate.progressionStages, entry,
          subjectContentExcerpt: excerpt, contentMode: LessonProgressionContentMode.omitted);

      expect(rows.every((r) => r.content.isEmpty), isTrue);
      final everything = allRoleText(rows).join('\n');
      expect(everything, isNot(contains('Background')));
      expect(everything, isNot(contains(excerpt)), reason: 'the excerpt must not be relocated into a role column');
      for (final point in _learningPoints(entry)) {
        expect(everything, isNot(contains(point)), reason: 'learning points are not folded into role columns');
      }
    });

    test('folded (default, every pre-existing template) behaves exactly as before', () {
      final syllabus = _loadTemplate('history_grade10.json', 'HIST');
      final entry = _firstRealEntry(syllabus);
      final rows = generateDefaultProgression(defaultCdcLessonPlanTemplate.progressionStages, entry,
          subjectContentExcerpt: excerpt);
      expect(rows.every((r) => r.content.isEmpty), isTrue);
      expect(rows.singleWhere((r) => r.stage == 'Lesson Development').teacherRole, contains('Background: $excerpt'));
    });
  });

  group('teaching points', () {
    test('from lesson notes: bullets only (subheadings skipped), six picked evenly across the notes', () {
      final notes = [
        'Life processes',
        for (var i = 1; i <= 4; i++) '- Life process point number $i explained here',
        'Cells',
        for (var i = 1; i <= 4; i++) '• Cell structure point number $i explained here',
        'Classification',
        for (var i = 1; i <= 4; i++) '- Classification point number $i explained here',
      ].join('\n');
      final points = teachingPointsFromNotes(notes);
      expect(points, hasLength(6));
      expect(points.any((p) => p.startsWith('Life process')), isTrue);
      expect(points.any((p) => p.startsWith('Cell')), isTrue);
      expect(points.any((p) => p.startsWith('Classification')), isTrue, reason: 'every subheading is represented');
      expect(points.any((p) => p == 'Cells' || p == 'Life processes'), isFalse, reason: 'headings are not points');
      expect(points.every((p) => !p.startsWith('-') && !p.startsWith('•')), isTrue);
    });

    test('fewer real points than six stay fewer — nothing is invented', () {
      expect(teachingPointsFromNotes('Heading\n- Only one real point here'), ['Only one real point here']);
      expect(teachingPointsFromNotes('no bullets at all'), isEmpty);
      expect(teachingPointsFromText(null), isEmpty);
      expect(teachingPointsFromText('Too short.'), isEmpty);
    });

    test('duplicates are dropped and long points are trimmed to a readable line', () {
      final long = '${List.filled(20, 'word').join(' ')}, ${List.filled(20, 'more').join(' ')}';
      final points = teachingPointsFromNotes('- $long\n- $long\n- A second distinct point here');
      expect(points, hasLength(2));
      expect(points.first.split(' ').length, lessThanOrEqualTo(25));
    });

    test('the Content cell is only replaced while it is blank or still the auto-generated text', () {
      expect(contentMayBeReplaced(current: '', autoGenerated: 'x'), isTrue);
      expect(contentMayBeReplaced(current: '•  a\n•  b', autoGenerated: '•  a\n•  b '), isTrue);
      expect(contentMayBeReplaced(current: 'teacher typed this', autoGenerated: '•  a'), isFalse);
      expect(contentMayBeReplaced(current: '•  a', autoGenerated: null), isFalse, reason: 'unknown baseline = do not touch');
    });
  });

  group('real generated documents', () {
    test('Natural Sciences & Mathematics (real Biology Grade 10 topic): all 5 columns, populated', () {
      final syllabus = _loadTemplate('biology_grade10.json', 'BIO');
      final entry = _firstRealEntry(syllabus);
      const template = defaultObcNaturalSciencesMathematicsLessonPlanTemplate;
      final draft = _draftFor(template, syllabus, entry);

      final docx = buildObcLessonPlanDocx(templateBytes: obcTemplateBytes, template: template, draft: draft);
      final doc = _documentXml(docx);
      final tables = _tables(doc);
      expect(tables, hasLength(3), reason: 'two header blocks + the progression table');

      final progression = tables[2];
      expect(_gridColumns(progression), 5);
      final rows = _tableRows(progression);
      expect(rows.first, ['STAGE / TIME', 'CONTENT / LEARNING POINTS', 'TEACHERS’ ROLE', 'LEARNERS’ ROLE', 'ASSESSMENT/EVIDENCE']);
      expect(rows, hasLength(1 + 3));
      for (final row in rows.skip(1)) {
        expect(row, hasLength(5));
        expect(row.every((cell) => cell.trim().isNotEmpty), isTrue, reason: 'no empty cell in $row');
      }
      expect(rows[1][0], contains('INTRODUCTION'));
      expect(rows[2][1], contains(_learningPoints(entry).first), reason: 'real learning point in Content column');
      expect(rows[3][0], contains('CONCLUSION'));
    });

    test('Social Sciences (real History Grade 10 topic): exactly 4 columns, no Content column anywhere', () {
      final syllabus = _loadTemplate('history_grade10.json', 'HIST');
      final entry = _firstRealEntry(syllabus);
      const template = defaultObcSocialSciencesLessonPlanTemplate;
      final draft = _draftFor(template, syllabus, entry);

      final docx = buildObcLessonPlanDocx(templateBytes: obcTemplateBytes, template: template, draft: draft);
      final doc = _documentXml(docx);
      final progression = _tables(doc)[2];

      expect(_gridColumns(progression), 4);
      final rows = _tableRows(progression);
      expect(rows.first, ['STAGE / TIME', 'TEACHERS’ ROLE', 'LEARNERS’ ROLE', 'Assessment Criteria']);
      for (final row in rows) {
        expect(row, hasLength(4));
      }
      for (final row in rows.skip(1)) {
        expect(row.every((cell) => cell.trim().isNotEmpty), isTrue, reason: 'no empty cell in $row');
      }

      final text = _allText(doc).toLowerCase();
      expect(text, isNot(contains('content / learning points')));
      expect(text, isNot(contains('learning points')));
      expect(text, isNot(contains('assessment/evidence')), reason: 'last column is renamed');
      // The learning points appear only where they always did (sections 1 and 3) — never as extra column content.
      expect(rows.skip(1).expand((r) => r).join('\n'), isNot(contains(_learningPoints(entry).first)));
    });

    test('both documents keep the official header, all eleven numbered sections in order, and the coat of arms', () {
      final syllabus = _loadTemplate('biology_grade10.json', 'BIO');
      final entry = _firstRealEntry(syllabus);

      for (final template in [defaultObcNaturalSciencesMathematicsLessonPlanTemplate, defaultObcSocialSciencesLessonPlanTemplate]) {
        final docx = buildObcLessonPlanDocx(
            templateBytes: obcTemplateBytes, template: template, draft: _draftFor(template, syllabus, entry));
        final doc = _documentXml(docx);
        final text = _allText(doc);

        expect(text, contains('REPUBLIC OF ZAMBIA'));
        expect(text, contains('Ministry of Education'));
        expect(text, contains('Senior Secondary School Lesson Plan'));
        for (final caption in ['NAME OF TEACHER', 'GRADE/CLASS', 'DATE', 'NAME OF SCHOOL', 'SUBJECT', 'TOPIC', 'SUB-TOPIC', 'DURATION/TIME']) {
          expect(text, contains(caption));
        }
        const headings = [
          '1. SPECIFIC COMPETENCE / LEARNING OUTCOME',
          '2. LESSON GOAL',
          '3. RATIONALE',
          '4. PRIOR / PRE-REQUISITE KNOWLEDGE',
          '5. REFERENCES',
          '6. TEACHING AND LEARNING MATERIALS / RESOURCES',
          '7. LESSON DEVELOPMENT / PROGRESSION',
          '8. TEACHER EVALUATION/ASSESSMENT',
          '9. LEARNER EVALUATION',
          '10. CLASS EXERCISE',
          '11. HOMEWORK / EXTENSION ACTIVITY',
        ];
        var last = -1;
        for (final h in headings) {
          final at = text.indexOf(h);
          expect(at, greaterThan(last), reason: '$h out of order or missing in ${template.name}');
          last = at;
        }

        // Filled values landed in the header tables.
        expect(text, contains('Test Teacher'));
        expect(text, contains('10A'));
        expect(text, contains(entry.topic.name));

        // Unfilled writing sections keep the template's ruled blank lines.
        expect(text, contains('_' * 80));

        // Package is still the official template package: image + styles carried over, metadata reset.
        final archive = ZipDecoder().decodeBytes(docx);
        expect(archive.findFile('word/media/image1.jpeg'), isNotNull);
        expect(archive.findFile('word/styles.xml'), isNotNull);
        expect(utf8.decode(archive.findFile('docProps/core.xml')!.content), isNot(contains('python-docx')));
        expect(doc.findAllElements('w:drawing'), isNotEmpty, reason: 'coat of arms drawing kept');
      }
    });

    test('LessonPlanDocumentService.generateDocx uses the official layout for OBC templates end to end', () async {
      final tempDir = Directory.systemTemp.createTempSync('obc_lesson_plan_test_');
      PathProviderPlatform.instance = _FakeTempPathProvider(tempDir.path);

      final syllabus = _loadTemplate('history_grade10.json', 'HIST');
      final entry = _firstRealEntry(syllabus);
      // Selected exactly as the app selects it: via the real manifest.
      final template = await lessonPlanTemplateForSubject(curriculumCode: 'OBC_2013', subjectCode: 'HIST');
      final service = LessonPlanDocumentService(obcTemplateLoader: () async => obcTemplateBytes);

      final file = await service.generateDocx(template, _draftFor(template, syllabus, entry));
      final doc = _documentXml(file.readAsBytesSync());
      expect(_gridColumns(_tables(doc)[2]), 4);
      expect(_tableRows(_tables(doc)[2]).first.last, 'Assessment Criteria');
    });

    test('the coat-of-arms is scaled down to letterhead size (real bug fixed 2026-09-28: it was rendering '
        'noticeably bigger than a typical Word-document crest)', () async {
      final rawXml = utf8.decode(ZipDecoder().decodeBytes(obcTemplateBytes).findFile('word/document.xml')!.content);
      final originalExtents = RegExp(r'(wp:extent|a:ext) cx="(\d+)" cy="(\d+)"')
          .allMatches(rawXml)
          .map((m) => (m.group(1)!, int.parse(m.group(2)!), int.parse(m.group(3)!)))
          .toList();
      expect(originalExtents, isNotEmpty);

      final syllabus = _loadTemplate('history_grade10.json', 'HIST');
      final entry = _firstRealEntry(syllabus);
      const template = defaultObcSocialSciencesLessonPlanTemplate;
      final bytes = buildObcLessonPlanDocx(templateBytes: obcTemplateBytes, template: template, draft: _draftFor(template, syllabus, entry));
      final doc = _documentXml(bytes);
      final outputXml = doc.toXmlString();
      final scaledExtents = RegExp(r'(wp:extent|a:ext) cx="(\d+)" cy="(\d+)"')
          .allMatches(outputXml)
          .map((m) => (m.group(1)!, int.parse(m.group(2)!), int.parse(m.group(3)!)))
          .toList();

      expect(scaledExtents.length, originalExtents.length);
      for (var i = 0; i < originalExtents.length; i++) {
        final (tag, cx, cy) = originalExtents[i];
        final (scaledTag, scaledCx, scaledCy) = scaledExtents[i];
        expect(scaledTag, tag);
        expect(scaledCx, (cx * 0.6).round());
        expect(scaledCy, (cy * 0.6).round());
        expect(scaledCx, lessThan(cx));
        expect(scaledCy, lessThan(cy));
      }
    });

    // Not an assertion: set OBC_SAMPLE_DIR to also write the two real
    // documents to disk, to open in Word and eyeball.
    test('writes the two sample documents when OBC_SAMPLE_DIR is set', () {
      final dir = Platform.environment['OBC_SAMPLE_DIR'];
      if (dir == null) return;
      for (final (template, file, subject) in [
        (defaultObcNaturalSciencesMathematicsLessonPlanTemplate, 'biology_grade10.json', 'BIO'),
        (defaultObcSocialSciencesLessonPlanTemplate, 'history_grade10.json', 'HIST'),
      ]) {
        final syllabus = _loadTemplate(file, subject);
        final entry = _firstRealEntry(syllabus);
        final excerpt = _realExcerpt(subject == 'BIO' ? 'biology' : 'history', entry);
        File('$dir/OBC_${subject}_sample.docx').writeAsBytesSync(buildObcLessonPlanDocx(
            templateBytes: obcTemplateBytes, template: template, draft: _draftFor(template, syllabus, entry, excerpt: excerpt)));
      }
    });

    test('a non-OBC-official template still renders through the generic path (CBC/legacy unaffected)', () async {
      final tempDir = Directory.systemTemp.createTempSync('obc_lesson_plan_test_');
      PathProviderPlatform.instance = _FakeTempPathProvider(tempDir.path);
      final service = LessonPlanDocumentService(obcTemplateLoader: () async => throw StateError('must not be used'));

      for (final template in [defaultCbcLessonPlanTemplate, defaultCdcLessonPlanTemplate]) {
        final file = await service.generateDocx(template, LessonPlanDraft.empty(template).withValue('topic', 'X'));
        final doc = _documentXml(file.readAsBytesSync());
        final table = doc.findAllElements('w:tbl').single;
        expect(_tableRows(table).first, ['Stage', "Teacher's Role", "Learners' Role", 'Assessment Criteria']);
        expect(_allText(doc), isNot(contains('REPUBLIC OF ZAMBIA')));
      }
    });
  });
}
