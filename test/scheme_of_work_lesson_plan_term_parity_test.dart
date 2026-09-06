// A real, permanent regression test (2026-09-06) for a real reported bug:
// "Generate Scheme of Work" placed a topic authored under a LATER term
// (physical_education_grade10.json's Term 3 "PE10.9.2 First Aid
// Techniques") into an earlier term's generated document — a real,
// documented, deliberate behaviour of generateSchemeOfWorkForTerm (a
// term's real teaching weeks can outnumber a sparse subject's own topics
// for that term, so the generator pulls forward whatever comes next in
// the whole-syllabus sequence to fill the remaining real weeks — see that
// function's own doc comment). TermTopicPickerScreen (the topic picker
// "Generate Lesson Plan" and every other topic-first feature share) used
// to group topics by each topic's own AUTHORED JSON term instead, so a
// topic a generated Scheme of Work had already placed under one term
// could only ever be found under a DIFFERENT term here — a teacher who
// had just generated a Term 1 Scheme of Work naming "PE10.9.2" could never
// find it while picking a Term 1 topic to write a lesson plan for.
//
// The fix (schemeOfWorkTermWindows, in lib/models/scheme_of_work.dart) is
// the one place both the Scheme of Work generator and
// TermTopicPickerScreen now read term/week placement from — this test
// locks in that both keep computing that placement the SAME way, using
// physical_education_grade10.json's own real, sparse data as the exact
// case that first exposed the mismatch.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
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
  test(
      'schemeOfWorkTermWindows places PE10.9.2 in the SAME term a fresh '
      'Scheme of Work generation would (not its own authored Term 3)', () {
    final template = _loadTemplate('assets/syllabi/physical_education_grade10.json', 'pe10');
    final windows = schemeOfWorkTermWindows(template);
    expect(windows.length, 3);

    bool windowContains(List<SchemeOfWorkEntry> window, String needle) =>
        window.any((e) => e.title.contains(needle));

    // Term 1's 10 own real entries only fill 10 of the term's 11 real
    // teaching weeks, so a fresh Scheme of Work's Term 1 pulls its 11th
    // week from Term 2's own first topic (PE10.6.1) — never as far as
    // PE10.9.2, which needs a further 3 entries of spillover room.
    expect(windowContains(windows[0], 'PE10.9.2'), isFalse,
        reason: 'Term 1 only has enough real teaching weeks to spill one topic into Term 2, not into Term 3');
    expect(windowContains(windows[0], 'PE10.6.1 Human Body Systems'), isTrue,
        reason: "Term 1's real 11th week is genuinely Term 2's own first topic — this is correct spillover, not a bug");

    // PE10.9.2 is where the whole-syllabus sequence actually lands once starting
    // from right after Term 1's window — Term 2's own window.
    expect(windowContains(windows[1], 'PE10.9.2'), isTrue,
        reason: 'A fresh class reaches PE10.9.2 (authored under Term 3 in the syllabus JSON) while still in Term 2, '
            'by real calendar coverage — TermTopicPickerScreen must show it there too, not under Term 3');

    // No entry should ever appear in two different terms' windows at once —
    // every real topic/sub-topic is taught exactly once.
    final seenTitles = <String>{};
    for (final window in windows) {
      for (final entry in window) {
        expect(seenTitles.add(entry.title), isTrue, reason: '"${entry.title}" appeared in more than one term window');
      }
    }
  });

  test('every syllabus term window is internally consistent with generateSchemeOfWorkForTerm chaining', () {
    // Any bundled syllabus: chaining schemeOfWorkTermWindows must visit
    // every entry generateSchemeOfWork(template, null) would, in the same
    // order, with no entry skipped or duplicated across term windows.
    final files = Directory('assets/syllabi')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json') && !f.path.endsWith('manifest.json'));

    for (final f in files) {
      final label = f.uri.pathSegments.last.replaceAll('.json', '');
      final template = _loadTemplate(f.path, label);
      final windows = schemeOfWorkTermWindows(template);
      final flattenedTitles = [for (final w in windows) for (final e in w) e.title];
      final wholeSyllabusTitles = allSchemeOfWorkEntries(template).map((e) => e.title).toList();

      // Every window entry must come from the real syllabus, in the real
      // authored order, with no repeats — i.e. flattenedTitles is exactly
      // wholeSyllabusTitles truncated wherever the last term's window ran
      // out of real teaching weeks (it never reorders or duplicates).
      expect(flattenedTitles.length <= wholeSyllabusTitles.length, isTrue, reason: '$label: more window entries than real topics exist');
      expect(flattenedTitles, wholeSyllabusTitles.sublist(0, flattenedTitles.length), reason: '$label: window entries drifted out of real syllabus order');
    }
  });
}
