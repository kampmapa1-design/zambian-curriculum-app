// A real, permanent regression test (2026-09-11) for a confirmed,
// shipped bug: MarkedResultsListsScreen ("My Results Lists") called
// `catalog.lists..sort(...)` directly on a repository's returned list.
// Every catalog model in this app follows the identical `.empty()`
// pattern — `const SomeCatalog(field: [])` — and a Dart `const []` is
// genuinely unmodifiable, not just conceptually immutable: sorting it IN
// PLACE (`..sort()`, which mutates its receiver) threw
// "Unsupported operation: Cannot modify an unmodifiable list" every time
// a screen loaded before its catalog file existed yet (a fresh install,
// or "no results lists created yet"). Worse, the screen's own `_load()`
// had no try/catch at the time, so the exception was silently swallowed
// by the Future machinery and `_loading` stayed true forever — "it's
// coming up empty, and it keeps on scrolling, like it is processing, but
// without putting up any list at all," reported by a real user, before
// the same fix that added error-surfacing also revealed this exact
// message.
//
// The real fix (marked_results_lists_screen.dart) was `.toList()` before
// `..sort()`, which every OTHER sort call site in this app already did —
// confirmed via a full `..sort(` sweep across lib/, this was the only
// site missing it. This test locks in the underlying hazard this whole
// class of bug stems from, across every real catalog model in the app,
// so a future direct `catalogField..mutatingMethod()` call site gets
// caught immediately in development rather than shipped.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/assignment_submission.dart';
import 'package:zambian_curriculum_app/models/generated_report_form.dart';
import 'package:zambian_curriculum_app/models/marked_results_list.dart';
import 'package:zambian_curriculum_app/models/marking_scheme.dart';
import 'package:zambian_curriculum_app/models/marking_script.dart';
import 'package:zambian_curriculum_app/models/minutes_session.dart';
import 'package:zambian_curriculum_app/models/subject_content_item.dart';
import 'package:zambian_curriculum_app/models/test_submission.dart';

void main() {
  test(
      'every catalog model\'s .empty() list is genuinely unmodifiable — '
      'a direct ..sort()/..add() on it throws, so it must always be copied with .toList() first', () {
    expect(() => MarkedResultsListCatalog.empty().lists.sort((a, b) => 0), throwsUnsupportedError);
    expect(() => MarkingSchemeCatalog.empty().schemes.sort((a, b) => 0), throwsUnsupportedError);
    expect(() => MarkingScriptCatalog.empty().scripts.sort((a, b) => 0), throwsUnsupportedError);
    expect(() => MinutesSessionCatalog.empty().sessions.sort((a, b) => 0), throwsUnsupportedError);
    expect(() => SubjectContentCatalog.empty().items.sort((a, b) => 0), throwsUnsupportedError);
    expect(() => AssignmentSubmissionCatalog.empty().submissions.sort((a, b) => 0), throwsUnsupportedError);
    expect(() => TestSubmissionCatalog.empty().submissions.sort((a, b) => 0), throwsUnsupportedError);
    expect(() => GeneratedReportFormCatalog.empty().reports.sort((a, b) => 0), throwsUnsupportedError);
  });

  test('the real fix — .toList() before sorting — always works, even on an .empty() catalog', () {
    // Mirrors marked_results_lists_screen.dart's own corrected _load()
    // exactly: this must never throw, unlike the direct-mutation version
    // above.
    final sorted = MarkedResultsListCatalog.empty().lists.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    expect(sorted, isEmpty);
  });
}
