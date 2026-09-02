// Regression test (2026-09-02) for the "resume where a class left off"
// capability added to generateSchemeOfWork/generateSchemeOfWorkForTerm —
// see ClassResumePickerScreen/ClassProgressRepository for the feature this
// backs. Hand-built minimal templates rather than a real bundled syllabus
// file, so every case below is exact and easy to reason about: sub-topic-
// level resume within a topic, topic-level resume skipping a whole topic's
// remaining sub-topics, resuming across a term boundary, and the real-
// teaching-week cap.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work_document.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work_template.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';
import 'package:zambian_curriculum_app/models/zambian_term_calendar.dart';

Competency _competency(int id) => Competency(id: id, sequenceNumber: 1, description: 'competency $id');

SubTopic _subTopic(int id, String name) => SubTopic(
      id: id,
      sequenceNumber: id,
      name: name,
      competencies: [_competency(id)],
      objectives: const [],
    );

Topic _topicWithSubTopics(int id, String name, List<SubTopic> subTopics) => Topic(
      id: id,
      sequenceNumber: id,
      name: name,
      subTopics: subTopics,
      competencies: const [],
      objectives: const [],
    );

void main() {
  // Term 1: Topic A (3 sub-topics), Topic B (2 sub-topics).
  // Term 2: Topic C (1 sub-topic), Topic D (1 sub-topic).
  final subA1 = _subTopic(101, 'A.1');
  final subA2 = _subTopic(102, 'A.2');
  final subA3 = _subTopic(103, 'A.3');
  final topicA = _topicWithSubTopics(1, 'Topic A', [subA1, subA2, subA3]);

  final subB1 = _subTopic(201, 'B.1');
  final subB2 = _subTopic(202, 'B.2');
  final topicB = _topicWithSubTopics(2, 'Topic B', [subB1, subB2]);

  final subC1 = _subTopic(301, 'C.1');
  final topicC = _topicWithSubTopics(3, 'Topic C', [subC1]);

  final subD1 = _subTopic(401, 'D.1');
  final topicD = _topicWithSubTopics(4, 'Topic D', [subD1]);

  final template = SyllabusTemplate(
    curriculum: const Curriculum(id: 1, code: 'X', name: 'X'),
    subject: const Subject(id: 1, curriculumId: 1, code: 'SUBJ', name: 'Subject'),
    grade: const Grade(id: 1, curriculumId: 1, code: 'G', name: 'Grade', level: 10),
    terms: [
      Term(id: 1, sequenceNumber: 1, name: 'Term 1', topics: [topicA, topicB]),
      Term(id: 2, sequenceNumber: 2, name: 'Term 2', topics: [topicC, topicD]),
    ],
  );

  test('sub-topic-level resume continues within the same topic, not the next one', () {
    // Concluded exactly A.2 - A.3 should come next, then Topic B's own
    // sub-topics, not a jump straight to Topic B skipping A.3.
    final entries = generateSchemeOfWork(template, topicA.id, lastConcludedSubTopicId: subA2.id);
    expect(entries.map((e) => e.subTopic?.name).toList(), [
      'A.3', 'B.1', 'B.2', 'C.1', 'D.1',
    ]);
  });

  test('topic-level resume (no sub-topic) skips the WHOLE topic, including remaining sub-topics', () {
    // Concluded Topic A entirely - resumes at Topic B, never revisiting any
    // of A's own sub-topics (the existing, pre-this-feature contract).
    final entries = generateSchemeOfWork(template, topicA.id);
    expect(entries.map((e) => e.subTopic?.name).toList(), [
      'B.1', 'B.2', 'C.1', 'D.1',
    ]);
  });

  test('resume correctly spills across a term boundary', () {
    // Concluded through B.2 (the very last entry of Term 1) - the next
    // entry is Topic C, which was filed under Term 2 in this template, not
    // an empty result just because Term 1 ran out.
    final entries = generateSchemeOfWork(template, topicB.id, lastConcludedSubTopicId: subB2.id);
    expect(entries.map((e) => e.subTopic?.name).toList(), ['C.1', 'D.1']);
  });

  test('resuming from the very last entry in the whole subject returns nothing left to cover', () {
    final entries = generateSchemeOfWork(template, topicD.id, lastConcludedSubTopicId: subD1.id);
    expect(entries, isEmpty);
  });

  test('null resume point starts from the very first entry of the whole subject', () {
    final entries = generateSchemeOfWork(template, null);
    expect(entries.map((e) => e.subTopic?.name).toList(), ['A.1', 'A.2', 'A.3', 'B.1', 'B.2', 'C.1', 'D.1']);
    // Renumbered sequentially from 1, regardless of original term/topic.
    expect(entries.map((e) => e.weekNumber).toList(), [1, 2, 3, 4, 5, 6, 7]);
  });

  test('generateSchemeOfWorkForTerm caps output at the real teaching-week count', () {
    // 7 real entries total in this template, well under the cap - confirms
    // the cap doesn't truncate when there's nothing to truncate.
    final uncapped = generateSchemeOfWorkForTerm(template, null);
    expect(uncapped.length, 7);
    expect(uncapped.length, lessThanOrEqualTo(TermDates.teachingWeekCount));

    // A template with more entries than one term's real teaching weeks
    // must be capped, not returned in full.
    final manySubTopics = [for (var i = 0; i < TermDates.teachingWeekCount + 5; i++) _subTopic(1000 + i, 'S$i')];
    final bigTemplate = SyllabusTemplate(
      curriculum: template.curriculum,
      subject: template.subject,
      grade: template.grade,
      terms: [Term(id: 9, sequenceNumber: 1, name: 'Term 1', topics: [_topicWithSubTopics(9, 'Big Topic', manySubTopics)])],
    );
    final capped = generateSchemeOfWorkForTerm(bigTemplate, null);
    expect(capped.length, TermDates.teachingWeekCount);
  });

  test('a generated document always shows a clean 1..N week count, even when the underlying '
      'entries carry real week numbers from two different original terms', () {
    // Reproduces the exact reported bug: a class resumes partway through
    // Term A (its own real weeks 7-9) and the scheme spills into Term B's
    // own topics (real weeks 1-3) - the DOCUMENT must read 1, 2, 3, 4, 5,
    // 6, not "7, 8, 9, 1, 2, 3".
    // SubTopic's weekNumber can't be set via the shared _subTopic helper
    // (it always leaves weekNumber null) - build these directly instead,
    // with real week numbers matching each one's ORIGINAL term.
    final subA = SubTopic(id: 1, sequenceNumber: 1, name: 'A tail', weekNumber: 7, competencies: [_competency(1)]);
    final subA2 = SubTopic(id: 2, sequenceNumber: 2, name: 'A tail 2', weekNumber: 8, competencies: [_competency(2)]);
    final subA3 = SubTopic(id: 3, sequenceNumber: 3, name: 'A tail 3', weekNumber: 9, competencies: [_competency(3)]);
    final headOfTermB1 = SubTopic(id: 4, sequenceNumber: 1, name: 'B head', weekNumber: 1, competencies: [_competency(4)]);
    final headOfTermB2 = SubTopic(id: 5, sequenceNumber: 2, name: 'B head 2', weekNumber: 2, competencies: [_competency(5)]);
    final headOfTermB3 = SubTopic(id: 6, sequenceNumber: 3, name: 'B head 3', weekNumber: 3, competencies: [_competency(6)]);

    final topicA = _topicWithSubTopics(10, 'Tail Topic', [subA, subA2, subA3]);
    final topicB = _topicWithSubTopics(20, 'Head Topic', [headOfTermB1, headOfTermB2, headOfTermB3]);

    final spanningTemplate = SyllabusTemplate(
      curriculum: const Curriculum(id: 1, code: 'X', name: 'X'),
      subject: const Subject(id: 1, curriculumId: 1, code: 'SUBJ', name: 'Subject'),
      grade: const Grade(id: 1, curriculumId: 1, code: 'G', name: 'Grade', level: 10),
      terms: [
        Term(id: 1, sequenceNumber: 1, name: 'Term A', topics: [topicA]),
        Term(id: 2, sequenceNumber: 2, name: 'Term B', topics: [topicB]),
      ],
    );

    final entries = generateSchemeOfWorkForTerm(spanningTemplate, null);
    final draft = SchemeOfWorkDocumentDraft.fromEntries(entries, curriculumCode: 'OBC_2013', subjectName: 'Subject');

    // Every real sourced week number in the underlying data (7,8,9,1,2,3)
    // is completely irrelevant to what's shown - the document's own "week"
    // column must be a clean, gapless 1..N count matching row position.
    final weekColumn = [for (final row in draft.rows) row.value(SchemeOfWorkColumnDef(id: 'week', label: 'Week'))];
    for (var i = 0; i < weekColumn.length; i++) {
      expect(weekColumn[i], '${i + 1}');
    }
  });

  test('week numbers are always plain numerals, never spelled out as words', () {
    final template2 = SyllabusTemplate(
      curriculum: const Curriculum(id: 1, code: 'X', name: 'X'),
      subject: const Subject(id: 1, curriculumId: 1, code: 'SUBJ', name: 'Subject'),
      grade: const Grade(id: 1, curriculumId: 1, code: 'G', name: 'Grade', level: 10),
      terms: [
        Term(id: 1, sequenceNumber: 1, name: 'Term 1', topics: [
          _topicWithSubTopics(1, 'Topic', [_subTopic(1, 'Sub 1'), _subTopic(2, 'Sub 2')]),
        ]),
      ],
    );
    final entries = generateSchemeOfWork(template2, null);
    for (final curriculumCode in ['CBC_2023', 'OBC_2013']) {
      final draft = SchemeOfWorkDocumentDraft.fromEntries(entries, curriculumCode: curriculumCode, subjectName: 'Subject');
      for (final row in draft.rows) {
        final week = row.value(SchemeOfWorkColumnDef(id: 'week', label: 'Week'));
        expect(int.tryParse(week), isNotNull, reason: 'Week value "$week" should be a plain numeral');
      }
    }
  });
}
