import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/report_class.dart';
import 'package:zambian_curriculum_app/services/report_form_document_service.dart';

void main() {
  test('every subject appears as its own row in the generated report form', () {
    final reportClass = ReportClass(
      id: 1,
      schoolName: 'Test Secondary School',
      classGrade: 'Grade 10A',
      term: 'Term 3, 2026',
      createdAt: DateTime(2026, 9, 1),
    );
    const learner = ReportLearner(id: 1, classId: 1, fullName: 'Test Learner', rosterOrder: 1);

    // Nine real subjects, matching the reported symptom exactly.
    final subjects = [
      for (var i = 1; i <= 9; i++) ReportSubject(id: i, classId: 1, name: 'Subject $i', sequenceNumber: i),
    ];
    final scores = {for (final s in subjects) s.id: 60.0 + s.id};
    final comments = {for (final s in subjects) s.id: 'Comment for ${s.name}'};

    final data = ReportFormMailMergeData(
      reportClass: reportClass,
      learner: learner,
      subjects: subjects,
      scores: scores,
      comments: comments,
      classPosition: 3,
      classSize: 30,
    );

    final bytes = ReportFormDocumentService().generateForLearner(data);
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentXmlFile = archive.files.firstWhere((f) => f.name == 'word/document.xml');
    final xml = utf8.decode(documentXmlFile.content as List<int>);

    for (final s in subjects) {
      expect(xml.contains(s.name), isTrue, reason: '${s.name} missing from generated document.xml');
    }

    // The document has two <w:tbl> tables: a 3-row bio-data grid (this
    // standalone, non-C.A. class has no 4th C.A.-weighting row), then the
    // subjects table (1 header row + one row per real subject, never
    // capped — see ReportFormMailMergeData.subjects). Total <w:tr> across
    // the whole document is the sum of both.
    final rowCount = RegExp('<w:tr>').allMatches(xml).length;
    const expectedBioGridRows = 3;
    const expectedSubjectsTableRows = 1 + 9; // header + one per subject
    expect(
      rowCount,
      expectedBioGridRows + expectedSubjectsTableRows,
      reason: 'Expected $expectedBioGridRows bio-grid rows + $expectedSubjectsTableRows subjects-table rows, '
          'found $rowCount <w:tr> elements total',
    );
  });
}
