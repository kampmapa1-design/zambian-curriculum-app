// A real, permanent regression test (2026-09-18), following the exact
// pattern already established by test/scheme_of_work_generation_test.dart:
// loads every real bundled syllabus JSON and runs each topic/sub-topic
// through the actual offline lesson-plan generator this app uses
// (generateDefaultProgression), for both of the app's two real bundled
// stage-name templates (see lesson_plan.dart's own default*Template
// constants) plus a custom/unrecognized stage name. This is the ONE
// engine of the app's five core generators that had zero automated test
// coverage before this file — notable given this exact area (lesson
// content matching/generation) is the one with the app's own documented
// history of silent failures.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';
import 'package:zambian_curriculum_app/services/lesson_progression_generator.dart';

// Real bundled stage-name lists — see lib/models/lesson_plan.dart's own
// defaultObcLessonPlanTemplate/defaultCbcLessonPlanTemplate constants.
// Deliberately copied here as literal strings, not imported, so this test
// still catches it if either bundled template's own stage wording ever
// drifts from what generateDefaultProgression's keyword matching expects.
const _obcStages = ['Introduction', 'Lesson Development', 'Exercise', 'Homework', 'Conclusion'];
const _cbcStages = ['Introduction', 'Development', 'Exercise', 'Homework', 'Conclusion'];

int _nextId = 1;

List<Competency> _parseCompetencies(Map<String, dynamic> json) => [
      for (final c in (json['competencies'] as List?) ?? const [])
        Competency(
          id: _nextId++,
          sequenceNumber: (c as Map<String, dynamic>)['sequence_number'] as int? ?? 0,
          description: c['description'] as String? ?? '',
          category: c['category'] as String?,
        ),
    ];

List<LearningObjective> _parseObjectives(Map<String, dynamic> json) => [
      for (final o in (json['objectives'] as List?) ?? const [])
        LearningObjective(
          id: _nextId++,
          sequenceNumber: (o as Map<String, dynamic>)['sequence_number'] as int? ?? 0,
          description: o['description'] as String? ?? '',
        ),
    ];

SyllabusTemplate _loadTemplate(String path, String label) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final termsJson = json['terms'] as List;
  final terms = <Term>[];
  for (var ti = 0; ti < termsJson.length; ti++) {
    final termJson = termsJson[ti] as Map<String, dynamic>;
    final topicsJson = termJson['topics'] as List;
    final topics = <Topic>[];
    for (var toi = 0; toi < topicsJson.length; toi++) {
      final topicJson = topicsJson[toi] as Map<String, dynamic>;
      final subTopicsJson = (topicJson['sub_topics'] as List?) ?? const [];
      final subTopics = <SubTopic>[];
      for (var si = 0; si < subTopicsJson.length; si++) {
        final subTopicJson = subTopicsJson[si] as Map<String, dynamic>;
        subTopics.add(SubTopic(
          id: _nextId++,
          sequenceNumber: si,
          name: subTopicJson['name'] as String,
          description: subTopicJson['description'] as String?,
          objectives: _parseObjectives(subTopicJson),
          competencies: _parseCompetencies(subTopicJson),
          weekNumber: subTopicJson['week_number'] as int?,
          references: subTopicJson['references'] as String?,
        ));
      }
      topics.add(Topic(
        id: _nextId++,
        sequenceNumber: toi,
        name: topicJson['name'] as String,
        description: topicJson['description'] as String?,
        subTopics: subTopics,
        objectives: _parseObjectives(topicJson),
        competencies: _parseCompetencies(topicJson),
        weekNumber: topicJson['week_number'] as int?,
        references: topicJson['references'] as String?,
      ));
    }
    terms.add(Term(id: _nextId++, sequenceNumber: ti, name: termJson['name'] as String, topics: topics));
  }
  return SyllabusTemplate(
    curriculum: const Curriculum(id: 1, code: 'X', name: 'X'),
    subject: Subject(id: 1, curriculumId: 1, code: label, name: label),
    grade: const Grade(id: 1, curriculumId: 1, code: 'G', name: 'G', level: 1),
    terms: terms,
  );
}

void main() {
  final files = Directory('assets/syllabi')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json') && !f.path.endsWith('manifest.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('at least one real syllabus file is bundled', () {
    expect(files, isNotEmpty);
  });

  for (final f in files) {
    final label = f.uri.pathSegments.last.replaceAll('.json', '');

    test('$label: every entry generates a default progression without throwing, for both bundled templates', () {
      final template = _loadTemplate(f.path, label);
      final entries = generateSchemeOfWork(template, null);
      expect(entries, isNotEmpty, reason: 'a bundled syllabus file with zero generated entries is itself a real bug');

      for (final entry in entries) {
        for (final stages in [_obcStages, _cbcStages]) {
          final rows = generateDefaultProgression(stages, entry);

          expect(rows, hasLength(stages.length), reason: 'one row per requested stage, in order, always — never dropped');
          expect(
            rows.map((r) => r.stage).toList(),
            stages,
            reason: 'row order/stage naming must exactly echo the template\'s own progressionStages',
          );

          // The real content requirement (see this generator's own doc
          // comment): every recognized stage gets real, non-empty
          // teacherRole/learnersRole content grounded in this entry's own
          // topic — never blank for a recognized stage, and never a
          // placeholder like "null" or "undefined" leaking through from a
          // missing field somewhere upstream.
          for (final row in rows) {
            expect(row.teacherRole, isNotEmpty, reason: '"${row.stage}" for "${entry.title}" in $label got no teacherRole');
            expect(row.teacherRole, isNot(contains('null')));
            expect(row.learnersRole, isNot(contains('null')));
          }
        }

        // A genuinely custom/unrecognized stage name (e.g. from a
        // teacher-uploaded template) must be left blank rather than
        // guessed — this is the generator's own documented contract, and
        // it must hold for every real entry, not just a synthetic example.
        final customRows = generateDefaultProgression(['A Totally Unrecognized Custom Stage Name'], entry);
        expect(customRows, hasLength(1));
        expect(customRows.single.teacherRole, isEmpty);
        expect(customRows.single.learnersRole, isEmpty);
        expect(customRows.single.assessmentCriteria, isEmpty);
      }
    });
  }

  group('subjectContentExcerpt (Development stage background material)', () {
    test('is included, capped, and never duplicates the competencies list', () {
      const entry = SchemeOfWorkEntry(
        weekNumber: 1,
        topic: Topic(id: 1, sequenceNumber: 0, name: 'Test Topic'),
        objectives: [],
        competencies: [Competency(id: 1, sequenceNumber: 0, description: 'A real competency', category: null)],
      );
      final longExcerpt = List.generate(200, (i) => 'word$i').join(' ');

      final rows = generateDefaultProgression(_cbcStages, entry, subjectContentExcerpt: longExcerpt);
      final development = rows.firstWhere((r) => r.stage == 'Development');

      expect(development.teacherRole, contains('Background:'));
      expect(development.teacherRole, isNot(contains('word199')), reason: 'must be capped, not included in full');
      expect(development.teacherRole, isNot(contains('A real competency')),
          reason: 'competencies are already printed elsewhere — must not be repeated here');
    });

    test('omitted entirely when no excerpt is given — no dangling "Background:" label', () {
      const entry = SchemeOfWorkEntry(
        weekNumber: 1,
        topic: Topic(id: 1, sequenceNumber: 0, name: 'Test Topic'),
        objectives: [],
        competencies: [],
      );

      final rows = generateDefaultProgression(_cbcStages, entry);
      final development = rows.firstWhere((r) => r.stage == 'Development');

      expect(development.teacherRole, isNot(contains('Background:')));
    });
  });
}
