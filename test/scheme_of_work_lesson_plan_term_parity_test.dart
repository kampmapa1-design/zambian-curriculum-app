// Two real, permanent regression tests, for two related but DIFFERENT
// real reported bugs:
//
// (2026-09-06) "Generate Scheme of Work" placed a topic authored under a
// LATER term (physical_education_grade10.json's Term 3 "PE10.9.2 First
// Aid Techniques") into an earlier term's generated document, while
// TermTopicPickerScreen (the topic picker "Generate Lesson Plan" and every
// other topic-first feature share) grouped topics by each topic's own
// AUTHORED JSON term instead — so a topic a generated Scheme of Work had
// already placed under one term could only ever be found under a
// DIFFERENT term when picking a topic to generate a lesson plan for.
//
// (2026-09-07) A follow-up, more serious bug from the FIRST fix's own
// chained-coverage model: for a subject with few total topics across the
// whole year (Physics Grade 11: 14 real entries; Principles of Accounts
// Form 2: 6), a FRESH generation (no real class history yet) front-loaded
// almost all of that content into Term 1's window, leaving Term 2 and/or
// Term 3 completely empty — "No topics left to place in this term" — even
// though the syllabus genuinely has real, authored content for those
// terms. Cross-term spillover only ever makes sense for a REAL class's own
// tracked resume point (real drift from the calendar); a fresh start has
// no history to justify assuming that drift, so it now always uses
// exactly each term's own authored topics — see
// generateSchemeOfWorkForTerm's and schemeOfWorkTermWindowsFrom's own doc
// comments in lib/models/scheme_of_work.dart.
//
// schemeOfWorkTermWindows/schemeOfWorkTermWindowsFrom (in
// lib/models/scheme_of_work.dart) is the one place both the Scheme of Work
// generator and TermTopicPickerScreen read term/week placement from — this
// file locks in both fixes together, since the second fix changes what
// "matching placement" for a fresh generation actually means.
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
      'schemeOfWorkTermWindows places PE10.9.2 under its OWN authored Term 3 '
      'for a fresh generation (no cross-term borrowing)', () {
    final template = _loadTemplate('assets/syllabi/physical_education_grade10.json', 'pe10');
    final windows = schemeOfWorkTermWindows(template);
    expect(windows.length, 3);

    bool windowContains(List<SchemeOfWorkEntry> window, String needle) =>
        window.any((e) => e.title.contains(needle));

    // A fresh generation has no real class history to justify borrowing
    // from a later term, so Term 1's window is exactly PE10.1–PE10.5 (its
    // own 10 real entries) — never PE10.9.2, and never PE10.6.1 either
    // (that's Term 2's own topic).
    expect(windows[0].length, 10, reason: "Term 1's window must be exactly its own 10 real entries, no more, no less");
    expect(windowContains(windows[0], 'PE10.9.2'), isFalse);
    expect(windowContains(windows[0], 'PE10.6.1'), isFalse,
        reason: 'PE10.6.1 is Term 2\'s own topic — a fresh Term 1 must not borrow it just to fill 11 weeks '
            '(applyCalendarPacing stretches Term 1\'s own 10 entries across the real 11 weeks instead)');

    expect(windowContains(windows[1], 'PE10.6.1'), isTrue, reason: "Term 2's own topics must appear in Term 2's window");
    expect(windowContains(windows[1], 'PE10.9.2'), isFalse);

    // PE10.9.2 is authored under Term 3 in the syllabus JSON — a fresh
    // Scheme of Work and the Lesson Plan topic picker must agree it lives
    // there, matching what the syllabus genuinely supports.
    expect(windowContains(windows[2], 'PE10.9.2'), isTrue,
        reason: 'PE10.9.2 is genuinely authored under Term 3 — a fresh generation must show it there, matching '
            'the real syllabus, not wherever whole-syllabus coverage happened to place it');

    // No entry should ever appear in two different terms' windows at once —
    // every real topic/sub-topic is taught exactly once.
    final seenTitles = <String>{};
    for (final window in windows) {
      for (final entry in window) {
        expect(seenTitles.add(entry.title), isTrue, reason: '"${entry.title}" appeared in more than one term window');
      }
    }
  });

  test(
      'a fresh schemeOfWorkTermWindows never leaves a term with real authored '
      'content showing "no topics left to place in this term"', () {
    // Real, reported bug (2026-09-07): Physics Grade 11 (14 real entries
    // across the whole year) and Principles of Accounts Form 2 (6) used to
    // have almost all of their content front-loaded into Term 1 by chained
    // whole-syllabus coverage, leaving later terms with genuinely-authored
    // content (Physics 11.7 Magnetism in Term 3; POA 2.3–2.5 in Terms 2–3)
    // showing as empty. Checked here across every bundled subject, not
    // just those two — the fix is general, not a special case for them.
    final files = Directory('assets/syllabi')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json') && !f.path.endsWith('manifest.json'));

    for (final f in files) {
      final label = f.uri.pathSegments.last.replaceAll('.json', '');
      final template = _loadTemplate(f.path, label);
      final windows = schemeOfWorkTermWindows(template);

      for (var i = 0; i < template.terms.length; i++) {
        final termHasRealTopics = template.terms[i].topics.isNotEmpty;
        if (termHasRealTopics) {
          expect(windows[i], isNotEmpty,
              reason: '$label: ${template.terms[i].name} has ${template.terms[i].topics.length} real authored '
                  'topic(s) but its fresh window came back empty');
        }
      }

      // Every term's window must be EXACTLY that term's own authored
      // entries — concatenating all of them must reconstruct the whole
      // syllabus exactly (same order, nothing dropped, nothing duplicated,
      // nothing borrowed from a different term).
      final flattenedTitles = [for (final w in windows) for (final e in w) e.title];
      final wholeSyllabusTitles = allSchemeOfWorkEntries(template).map((e) => e.title).toList();
      expect(flattenedTitles, wholeSyllabusTitles,
          reason: '$label: fresh term windows must exactly reconstruct the whole syllabus, term by term, with no '
              'cross-term borrowing and nothing dropped');
    }
  });

  test(
      'schemeOfWorkTermWindowsFrom (2026-09-06, per-class Lesson Plan parity) matches '
      "generateSchemeOfWorkForTerm's own real starting point, then keeps chaining safely", () {
    // design_and_technology_form1's "GRAPHICS" topic is exactly the shape
    // that broke naive id-based chaining (own content AND further
    // sub-topics) — resume from a class whose recorded progress says
    // "concluded up through GRAPHICS itself" (real ClassProgress semantics:
    // no sub-topic id means the WHOLE topic, GRAPHICS's own sub-topics
    // included, is done) and confirm the first window matches
    // generateSchemeOfWorkForTerm's own real output for that same resume
    // point exactly, while later windows still don't drop content.
    final template = _loadTemplate('assets/syllabi/design_and_technology_form1.json', 'dt1');
    // "GRAPHICS" is used as a topic name twice in this real syllabus (a
    // genuine content quirk, not a bug) — the one that actually exhibits
    // the "own content AND further sub-topics" shape is the one this test
    // needs, so find it by shape, not by name alone.
    final graphicsTopic = flattenTopics(template).firstWhere(
        (t) => t.name == 'GRAPHICS' && t.subTopics.isNotEmpty && (t.objectives.isNotEmpty || t.competencies.isNotEmpty));

    final expectedFirstWindow = generateSchemeOfWorkForTerm(template, graphicsTopic.id);
    final windows = schemeOfWorkTermWindowsFrom(template, graphicsTopic.id);

    expect(windows[0].map((e) => e.title).toList(), expectedFirstWindow.map((e) => e.title).toList(),
        reason: "The first window must match generateSchemeOfWorkForTerm's own real resume semantics exactly — "
            'the whole point is parity with what that class\'s actual Scheme of Work document shows');

    // GRAPHICS's own sub-topics (SYMBOLS, INTRODUCTION TO CAD) were
    // concluded along with GRAPHICS itself per the resume point above, so
    // they must NOT reappear in any later window either.
    final allTitles = [for (final w in windows) for (final e in w) e.title];
    expect(allTitles.where((t) => t.contains('GRAPHICS')), isEmpty,
        reason: 'GRAPHICS and its sub-topics were all marked concluded by this resume point — none should reappear');

    // No entry should ever appear in two different windows at once.
    final seenTitles = <String>{};
    for (final title in allTitles) {
      expect(seenTitles.add(title), isTrue, reason: '"$title" appeared in more than one term window');
    }
  });
}
