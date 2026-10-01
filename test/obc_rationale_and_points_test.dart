// OBC lesson plan follow-up (2026-09-26): the rationale has at most three
// points with no repeated action word, and the Development stage's Content
// cell never has fewer than six points — checked against EVERY real bundled
// OBC syllabus sub-topic, not just samples.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/lesson_plan.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';
import 'package:zambian_curriculum_app/services/lesson_progression_generator.dart';
import 'package:zambian_curriculum_app/services/lesson_rationale.dart';
import 'package:zambian_curriculum_app/services/lesson_teaching_points.dart';

String _verb(String point) => point.replaceFirst(RegExp(r'^•\s*'), '').trim().split(RegExp(r'\s+')).first.toLowerCase();

/// Every real classified OBC sub-topic's outcome list (competencies), straight
/// from the bundled JSON, for the subjects [wanted] accepts.
List<({String file, String name, List<String> outcomes})> _realSubTopics(bool Function(String code) wanted) {
  final manifest = jsonDecode(File('assets/syllabi/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final out = <({String file, String name, List<String> outcomes})>[];
  for (final e in (manifest['templates'] as List).cast<Map<String, dynamic>>()) {
    if (e['curriculum_code'] != 'OBC_2013' || e['subject_category'] == null || !wanted(e['subject_code'] as String)) continue;
    final json = jsonDecode(File('assets/syllabi/${e['file']}').readAsStringSync()) as Map<String, dynamic>;
    for (final term in json['terms'] as List) {
      for (final topic in (term as Map<String, dynamic>)['topics'] as List) {
        for (final st in ((topic as Map<String, dynamic>)['sub_topics'] as List?) ?? const []) {
          final s = st as Map<String, dynamic>;
          final outcomes = [for (final c in (s['competencies'] as List?) ?? const []) (c as Map)['description'] as String];
          if (outcomes.isNotEmpty) out.add((file: e['file'] as String, name: s['name'] as String, outcomes: outcomes));
        }
      }
    }
  }
  return out;
}

SchemeOfWorkEntry _entryFor(String name, List<String> outcomes) {
  final competencies = [
    for (var i = 0; i < outcomes.length; i++) Competency(id: i + 1, sequenceNumber: i + 1, description: outcomes[i]),
  ];
  final subTopic = SubTopic(id: 1, sequenceNumber: 1, name: name, objectives: const [], competencies: competencies);
  final topic =
      Topic(id: 1, sequenceNumber: 1, name: 'Topic', subTopics: [subTopic], objectives: const [], competencies: const []);
  return SchemeOfWorkEntry(weekNumber: 1, topic: topic, subTopic: subTopic, objectives: const [], competencies: competencies);
}

void main() {
  group('rationale', () {
    test('never more than three points, however many outcomes the syllabus lists', () {
      final outcomes = [for (var i = 0; i < 13; i++) 'Describe item number $i of the topic'];
      final text = buildObcRationale(outcomes)!;
      expect(text.split('\n').where((l) => l.startsWith('•')), hasLength(3));
    });

    test('repeated action words are re-worded so each point opens differently', () {
      final points = rationalePoints([
        'Describe an atom and its structure',
        'Describe the relative charges of protons',
        'Describe what an element is',
      ]);
      expect(points, hasLength(3));
      expect(points.map((p) => p.split(' ').first.toLowerCase()).toSet(), hasLength(3));
      expect(points.first, startsWith('Describe'), reason: 'the first keeps the syllabus wording');
      expect(points[1], contains('the relative charges of protons'), reason: 'only the verb changes');
    });

    test('outcomes that already differ are left exactly as the syllabus wrote them', () {
      const outcomes = ['Identify the parts of a cell', 'Explain how a cell divides', 'Calculate the magnification'];
      expect(rationalePoints(outcomes), outcomes);
    });

    test('prefers outcomes with different verbs when choosing which three to show', () {
      final points = rationalePoints(['Describe a', 'Describe b', 'Describe c', 'Explain d', 'Identify e']);
      expect(points.map(_verb), containsAll(['describe', 'explain', 'identify']));
    });

    test('no outcomes -> no rationale text', () {
      expect(buildObcRationale(const []), isNull);
    });

    test('EVERY real classified OBC sub-topic: at most 3 points and no opening verb repeated', () {
      final all = _realSubTopics((_) => true);
      expect(all, isNotEmpty);
      for (final st in all) {
        final points = rationalePoints(st.outcomes);
        expect(points.length, lessThanOrEqualTo(3), reason: '${st.file} ${st.name}');
        final verbs = points.map(_verb).toList();
        expect(verbs.toSet().length, verbs.length, reason: 'repeated verb in ${st.file} ${st.name}: $points');
      }
    });
  });

  group('Development content: never fewer than six points', () {
    LessonProgressionRow development(SchemeOfWorkEntry e, {String? excerpt}) => generateDefaultProgression(
          defaultObcNaturalSciencesMathematicsLessonPlanTemplate.progressionStages,
          e,
          subjectContentExcerpt: excerpt,
          contentMode: LessonProgressionContentMode.ownColumn,
        ).singleWhere((r) => r.stage == 'Development');

    test('a topic with a single outcome still gets six points, all anchored to that outcome', () {
      final row = development(_entryFor('10.9.1 Cells', ['Describe the structure of a cell']));
      final lines = row.content.split('\n');
      expect(lines, hasLength(6));
      expect(lines.first, '•  Describe the structure of a cell', reason: 'the real outcome comes first');
      expect(lines.skip(1).every((l) => l.contains('the structure of a cell')), isTrue);
    });

    test('a topic with no outcomes at all still gets six, anchored to the topic name', () {
      final row = development(_entryFor('10.9.1 Cells', const []));
      final lines = row.content.split('\n');
      expect(lines, hasLength(6));
      expect(lines.every((l) => l.contains('Cells')), isTrue);
      expect(lines.any((l) => l.contains('10.9.1')), isFalse, reason: 'the numbering is stripped');
    });

    test('real lesson material still comes first; six total; no padding when there is enough', () {
      const material = 'The structure of cells is the basic unit of life. All living things have the structure of cells. A '
          'cell membrane is part of the structure of cells. The nucleus is part of the structure of cells. Mitochondria '
          'are found in the structure of cells. Chloroplasts are found in the structure of plant cells.';
      final lines =
          development(_entryFor('Cells', ['Describe the structure of cells']), excerpt: material).content.split('\n');
      expect(lines, hasLength(6));
      expect(lines.first, '•  The structure of cells is the basic unit of life.');
      expect(lines.any((l) => l.startsWith('•  Meaning and key terms')), isFalse, reason: 'no scaffolds when material suffices');
    });

    test('EVERY real Natural Sciences & Mathematics sub-topic gets at least six points in Development', () {
      final all = _realSubTopics((code) => const {'BIO', 'CHEM', 'PHY', 'MATH', 'AGR'}.contains(code));
      expect(all.length, greaterThan(100));
      for (final st in all) {
        final lines = development(_entryFor(st.name, st.outcomes)).content.split('\n');
        expect(lines.length, greaterThanOrEqualTo(6), reason: '${st.file} ${st.name}');
        expect(lines.toSet().length, lines.length, reason: 'duplicate point in ${st.file} ${st.name}');
      }
    });

    test('a short AI/notes result is topped up to six without losing what it returned', () {
      final text = ensureContentText('•  Point one is here now\n•  Point two is here now',
          outcomes: ['Describe cells', 'Identify organelles'], topicLabel: '10.1 Cells');
      final lines = text.split('\n');
      expect(lines.length, greaterThanOrEqualTo(6));
      expect(lines.first, '•  Point one is here now');
      expect(lines[1], '•  Point two is here now');
    });

    test('six or more real points are never padded', () {
      final six = [for (var i = 1; i <= 6; i++) 'Real point number $i is here'];
      expect(ensureMinimumPoints(six, outcomes: ['Describe x'], topicLabel: 'T'), six);
    });
  });
}
