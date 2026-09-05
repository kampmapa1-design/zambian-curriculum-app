// Regression test (2026-09-05) for a real gap this same session's
// cohort-naming feature would otherwise have exposed: the same marking
// key genuinely gets reused across different classes/sittings (e.g.
// "History Paper 1" marked for both 12A and 12B), and grouping by
// schemeId alone would silently merge two different classes' scripts
// into one "Completed Marking Cohort" pass.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/marking_scheme.dart';
import 'package:zambian_curriculum_app/models/marking_script.dart';
import 'package:zambian_curriculum_app/services/marking_cohort_grouping.dart';

MarkingScheme _scheme(String id, String title) => MarkingScheme(
      id: id,
      title: title,
      subjectName: 'History',
      gradeName: 'Grade 12',
      topicName: 'Mock Exam',
      questions: const [MarkingSchemeQuestion(label: 'Q1', expectedAnswerOrKeywords: 'x', maxMarks: 10)],
      createdAt: DateTime(2026, 9, 5),
    );

MarkingScript _script(
  String id, {
  required String schemeId,
  required String cohortName,
  MarkingScriptStatus status = MarkingScriptStatus.reviewed,
}) =>
    MarkingScript(
      id: id,
      firstName: 'Jane',
      surname: 'Banda',
      gender: CandidateGender.female,
      scriptNumber: 1,
      subjectName: 'History',
      gradeName: 'Grade 12',
      cohortName: cohortName,
      pageFileNames: const ['page_01.jpg'],
      capturedAt: DateTime(2026, 9, 5),
      status: status,
      schemeId: schemeId,
    );

void main() {
  test('two different classes sharing one marking key stay two separate cohorts', () {
    final scheme = _scheme('s1', 'History Paper 1');
    final scripts = [
      _script('a', schemeId: 's1', cohortName: '12A'),
      _script('b', schemeId: 's1', cohortName: '12A'),
      _script('c', schemeId: 's1', cohortName: '12B'),
    ];
    final cohorts = activeMarkingCohorts(scripts, [scheme]);

    // The real reported risk: this used to be a single entry (grouped by
    // schemeId alone), which would have merged 12A and 12B's scripts into
    // one "cohort" despite being genuinely different classes.
    expect(cohorts.length, 2);
    final names = cohorts.map((c) => c.cohortName).toSet();
    expect(names, {'12A', '12B'});
  });

  test('scripts with no cohort name at all (old data) group under "" -- unchanged, scheme-only behavior', () {
    final scheme = _scheme('s1', 'History Paper 1');
    final scripts = [
      _script('a', schemeId: 's1', cohortName: ''),
      _script('b', schemeId: 's1', cohortName: ''),
    ];
    final cohorts = activeMarkingCohorts(scripts, [scheme]);
    expect(cohorts.length, 1);
    expect(cohorts.single.cohortName, '');
  });

  test('a script still only "captured" (not yet queued) is not part of any cohort yet', () {
    final scheme = _scheme('s1', 'History Paper 1');
    final scripts = [_script('a', schemeId: 's1', cohortName: '12A', status: MarkingScriptStatus.captured)];
    expect(activeMarkingCohorts(scripts, [scheme]), isEmpty);
  });

  test('a script whose scheme was since deleted is silently excluded, not a crash', () {
    final scripts = [_script('a', schemeId: 'deleted-scheme', cohortName: '12A')];
    expect(activeMarkingCohorts(scripts, const []), isEmpty);
  });

  group('markingCohortLabel', () {
    test('names the cohort first, so two classes sharing a scheme are never confused', () {
      final cohort = (scheme: _scheme('s1', 'History Paper 1'), cohortName: '12A');
      expect(markingCohortLabel(cohort), '12A — History Paper 1');
    });

    test('falls back to just the scheme title when there is no cohort name', () {
      final cohort = (scheme: _scheme('s1', 'History Paper 1'), cohortName: '');
      expect(markingCohortLabel(cohort), 'History Paper 1');
    });
  });
}
