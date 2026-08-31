// A real, permanent regression test (2026-08-31) — not a throwaway script.
// Loads every real bundled syllabus JSON (the same shape/field names the
// SQLite ingestion path reads, with sequential auto-increment-style ids
// assigned in the same order) and runs each one through the exact Scheme
// of Work generation code the app itself uses: generateSchemeOfWork,
// groupEntriesByRealWeek, and SchemeOfWorkDocumentDraft.fromEntries (which
// is what threw a real "Invalid argument(s)" exception for
// geography_grade12.json in production — 25 topics/sub-topics against
// only 12 real teaching weeks, a case applyCalendarPacing didn't handle).
//
// This exists so that class of bug — a generation crash for one specific
// real subject's real data shape — gets caught by `flutter test` before a
// build ships, not by a teacher hitting a blank page on a real device.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work_document.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work_template.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';

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
    test('$label generates a Scheme of Work without throwing', () {
      final template = _loadTemplate(f.path, label);
      final allEntries = generateSchemeOfWork(template, null);

      for (final term in template.terms) {
        final topicIdsInTerm = term.topics.map((t) => t.id).toSet();
        final termEntries = allEntries.where((e) => topicIdsInTerm.contains(e.topic.id)).toList();
        groupEntriesByRealWeek(termEntries);

        for (final curriculumCode in ['CBC_2023', 'OBC_2013']) {
          final draft = SchemeOfWorkDocumentDraft.fromEntries(termEntries, curriculumCode: curriculumCode, subjectName: label);
          for (final row in draft.rows) {
            for (final columnId in [
              'week',
              'stage',
              'topic',
              'subTopic',
              'topicSubTopic',
              'topicContent',
              'specificCompetence',
              'learningActivities',
              'references',
            ]) {
              row.value(SchemeOfWorkColumnDef(id: columnId, label: columnId));
            }
          }
        }
      }

      // Resuming from every real topic ("last taught X") must also never
      // throw — this is the actual "click a topic" user-facing path.
      for (final topic in flattenTopics(template)) {
        generateSchemeOfWork(template, topic.id);
      }
    });
  }
}
