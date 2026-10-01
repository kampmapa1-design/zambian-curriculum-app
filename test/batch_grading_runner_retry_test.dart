import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zambian_curriculum_app/models/marking_credits.dart';
import 'package:zambian_curriculum_app/models/marking_scheme.dart';
import 'package:zambian_curriculum_app/models/marking_script.dart';
import 'package:zambian_curriculum_app/services/batch_grading_runner.dart';
import 'package:zambian_curriculum_app/services/marking_credits_service.dart';
import 'package:zambian_curriculum_app/services/marking_grading_service.dart';
import 'package:zambian_curriculum_app/services/marking_script_repository.dart';

/// Regression test for a real bug: [runBatchGrading]'s retry path (the
/// `catch (firstError)` branch) called [MarkingGradingService.grade]
/// without `subjectName`, while the first attempt included it — an
/// undocumented inconsistency (see the app's own status report) rather
/// than a deliberate difference. Fixed by passing the same arguments on
/// both attempts; this test fails on the pre-fix code by asserting the
/// retry call's `subjectName` matches the first attempt's.
///
/// [_RecordingGradingService] overrides `grade()` entirely, so it never
/// touches the real `FirebaseFunctions.instance` — no Firebase app needs
/// to exist for this test (see MarkingGradingService's lazy `_functions`
/// getter, changed alongside this fix specifically to make that possible).
class _RecordingGradingService extends MarkingGradingService {
  _RecordingGradingService(this._onCall);

  final List<String?> subjectNamesSeen = [];
  final List<String?> requestIdsSeen = [];
  final MarkingGradingResult Function(int attemptNumber) _onCall;
  int _attempt = 0;

  @override
  Future<MarkingGradingResult> grade({
    required List<File> pageFiles,
    required MarkingScheme scheme,
    List<PreSegmentedAnswer>? preSegmentedAnswers,
    String? subjectName,
    String? requestId,
  }) async {
    _attempt++;
    subjectNamesSeen.add(subjectName);
    requestIdsSeen.add(requestId);
    if (_attempt == 1) throw const MarkingGradingUnavailable('simulated first-attempt failure');
    return _onCall(_attempt);
  }
}

/// Succeeds or throws per call, from a script of outcomes; records every call's request id.
class _ScriptedGradingService extends MarkingGradingService {
  _ScriptedGradingService(this.outcomes);

  final List<Object> outcomes; // a MarkingGradingResult to return, or an Exception to throw
  final List<String?> requestIdsSeen = [];
  final List<String?> subjectNamesSeen = [];
  int calls = 0;

  @override
  Future<MarkingGradingResult> grade({
    required List<File> pageFiles,
    required MarkingScheme scheme,
    List<PreSegmentedAnswer>? preSegmentedAnswers,
    String? subjectName,
    String? requestId,
  }) async {
    requestIdsSeen.add(requestId);
    subjectNamesSeen.add(subjectName);
    final outcome = outcomes[calls++];
    if (outcome is MarkingGradingResult) return outcome;
    throw outcome;
  }
}

class _FakeMarkingScriptRepository extends MarkingScriptRepository {
  final List<MarkingScript> updates = [];

  @override
  Future<List<File>> pageFilesFor(MarkingScript script) async => <File>[];

  @override
  Future<void> update(MarkingScript script) async {
    updates.add(script);
  }
}

MarkingScript _buildScript({required String subjectName, String id = 's1', MarkingScriptStatus status = MarkingScriptStatus.captured}) => MarkingScript(
      id: id,
      firstName: 'Test',
      surname: 'Candidate',
      gender: CandidateGender.male,
      scriptNumber: 1,
      subjectName: subjectName,
      gradeName: 'Grade 10',
      pageFileNames: const ['page1.jpg', 'page2.jpg'],
      capturedAt: DateTime(2026, 9, 18),
      status: status,
    );

MarkingScheme _buildScheme() => MarkingScheme(
      id: 'scheme1',
      title: 'Test scheme',
      subjectName: 'Mathematics',
      gradeName: 'Grade 10',
      topicName: 'Algebra',
      questions: const [
        MarkingSchemeQuestion(label: 'Q1', expectedAnswerOrKeywords: 'x = 5', maxMarks: 10),
      ],
      createdAt: DateTime(2026, 9, 18),
    );

const _ok = MarkingGradingResult(answers: [], observations: []);
const _noCredits = InsufficientCreditsException(requiredCredits: 6.6, availableCredits: 2, message: 'Not enough marking credits');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MarkingRequestIds.resetForTest();
    MarkingCreditsService.instance.seedForTest(config: null, balance: null);
  });

  test('retry attempt passes the same subjectName as the first attempt', () async {
    final gradingService = _RecordingGradingService(
      (attempt) => const MarkingGradingResult(answers: [], observations: []),
    );
    final repository = _FakeMarkingScriptRepository();
    final script = _buildScript(subjectName: 'Mathematics');

    await runBatchGrading(
      scripts: [script],
      scheme: _buildScheme(),
      repository: repository,
      gradingService: gradingService,
    );

    expect(gradingService.subjectNamesSeen.length, 2, reason: 'first attempt + one retry');
    expect(gradingService.subjectNamesSeen[0], 'Mathematics');
    expect(
      gradingService.subjectNamesSeen[1],
      'Mathematics',
      reason: 'retry must receive the same subjectName as the first attempt, not drop it',
    );

    expect(repository.updates.last.status, MarkingScriptStatus.graded);
  });

  test('script is left needsRetry with the error recorded when both attempts fail', () async {
    final gradingService = _RecordingGradingService(
      (attempt) => throw const MarkingGradingUnavailable('simulated second-attempt failure'),
    );
    final repository = _FakeMarkingScriptRepository();
    final script = _buildScript(subjectName: 'History');

    await runBatchGrading(
      scripts: [script],
      scheme: _buildScheme(),
      repository: repository,
      gradingService: gradingService,
    );

    expect(gradingService.subjectNamesSeen, ['History', 'History']);
    expect(repository.updates.last.status, MarkingScriptStatus.needsRetry);
    expect(repository.updates.last.lastError, isNotNull);
  });

  group('credits', () {
    test('BOTH attempts of one script carry the SAME request id (so the server charges it at most once)', () async {
      final service = _RecordingGradingService((_) => _ok);
      await runBatchGrading(
        scripts: [_buildScript(subjectName: 'Maths')],
        scheme: _buildScheme(),
        repository: _FakeMarkingScriptRepository(),
        gradingService: service,
      );
      expect(service.requestIdsSeen, hasLength(2));
      expect(service.requestIdsSeen[0], isNotNull);
      expect(service.requestIdsSeen[0], service.requestIdsSeen[1]);
    });

    test('different scripts get different request ids', () async {
      final service = _ScriptedGradingService([_ok, _ok]);
      await runBatchGrading(
        scripts: [_buildScript(subjectName: 'Maths', id: 'a'), _buildScript(subjectName: 'Maths', id: 'b')],
        scheme: _buildScheme(),
        repository: _FakeMarkingScriptRepository(),
        gradingService: service,
      );
      expect(service.requestIdsSeen.toSet(), hasLength(2));
    });

    test('a script that was marked gets a NEW id next time; one that failed keeps its id for the retry', () async {
      final scheme = _buildScheme();
      final ok = _ScriptedGradingService([_ok, _ok]);
      await runBatchGrading(scripts: [_buildScript(subjectName: 'M')], scheme: scheme, repository: _FakeMarkingScriptRepository(), gradingService: ok);
      await runBatchGrading(scripts: [_buildScript(subjectName: 'M')], scheme: scheme, repository: _FakeMarkingScriptRepository(), gradingService: ok);
      expect(ok.requestIdsSeen[0], isNot(ok.requestIdsSeen[1]), reason: 're-marking a marked script is a new, separately charged action');

      MarkingRequestIds.resetForTest();
      const fail = MarkingGradingUnavailable('boom');
      final failing = _ScriptedGradingService([fail, fail, fail, fail]);
      await runBatchGrading(scripts: [_buildScript(subjectName: 'M')], scheme: scheme, repository: _FakeMarkingScriptRepository(), gradingService: failing);
      await runBatchGrading(scripts: [_buildScript(subjectName: 'M')], scheme: scheme, repository: _FakeMarkingScriptRepository(), gradingService: failing);
      expect(failing.requestIdsSeen.toSet(), hasLength(1),
          reason: 'a failed script keeps its id, so a lost-response retry after the server already charged is not charged twice');
    });

    test('"not enough credits" is NOT retried, does not mark the script failed, and stops the batch', () async {
      final service = _ScriptedGradingService([_noCredits, _ok]);
      final repository = _FakeMarkingScriptRepository();
      InsufficientCreditsException? reason;
      var outOfCreditsCalls = 0;
      final first = _buildScript(subjectName: 'M', id: 'first', status: MarkingScriptStatus.queued);
      final second = _buildScript(subjectName: 'M', id: 'second', status: MarkingScriptStatus.queued);

      await runBatchGrading(
        scripts: [first, second],
        scheme: _buildScheme(),
        repository: repository,
        gradingService: service,
        onOutOfCredits: (r) {
          outOfCreditsCalls++;
          reason = r;
        },
      );

      expect(service.calls, 1, reason: 'no retry after a refusal, and the second script is never even tried');
      expect(outOfCreditsCalls, 1);
      expect(reason?.requiredCredits, 6.6);
      expect(reason?.availableCredits, 2);
      // The first script was put back exactly as it was (queued), never left "processing" or "needsRetry".
      expect(repository.updates.last.id, 'first');
      expect(repository.updates.last.status, MarkingScriptStatus.queued);
      expect(repository.updates.any((u) => u.status == MarkingScriptStatus.needsRetry), isFalse);
      expect(repository.updates.any((u) => u.id == 'second'), isFalse);
    });

    test('a refusal on the RETRY attempt (balance ran out in between) also stops cleanly', () async {
      final service = _ScriptedGradingService([const MarkingGradingUnavailable('blip'), _noCredits]);
      final repository = _FakeMarkingScriptRepository();
      var stopped = false;
      await runBatchGrading(
        scripts: [_buildScript(subjectName: 'M', status: MarkingScriptStatus.queued)],
        scheme: _buildScheme(),
        repository: repository,
        gradingService: service,
        onOutOfCredits: (_) => stopped = true,
      );
      expect(stopped, isTrue);
      expect(repository.updates.last.status, MarkingScriptStatus.queued);
    });

    test('the app-side courtesy check stops BEFORE any network call when the balance clearly cannot cover it', () async {
      // 2 pages of Key-based at 3.3 = 6.6 credits; only 1 available, credits enforced.
      MarkingCreditsService.instance.seedForTest(
        config: MarkingCreditsConfig.fromMap({'mode': 'enforced'}),
        balance: CreditBalance(freeCredits: 1, purchasedCredits: 0, freePeriod: periodKeyCat(DateTime.now())),
      );
      final service = _ScriptedGradingService([_ok]);
      final repository = _FakeMarkingScriptRepository();
      var reasonWasNull = false;
      await runBatchGrading(
        scripts: [_buildScript(subjectName: 'M', status: MarkingScriptStatus.queued)],
        scheme: _buildScheme(),
        repository: repository,
        gradingService: service,
        onOutOfCredits: (r) => reasonWasNull = r == null,
      );
      expect(service.calls, 0);
      expect(reasonWasNull, isTrue);
      expect(repository.updates, isEmpty, reason: 'the script is not touched at all');
    });

    test('with credits OFF, or an unknown balance, the check never blocks (the server is the gate)', () async {
      final scheme = _buildScheme();
      // off
      MarkingCreditsService.instance.seedForTest(
        config: MarkingCreditsConfig.fromMap({'mode': 'off'}),
        balance: CreditBalance(freeCredits: 0, purchasedCredits: 0, freePeriod: periodKeyCat(DateTime.now())),
      );
      final a = _ScriptedGradingService([_ok]);
      await runBatchGrading(scripts: [_buildScript(subjectName: 'M')], scheme: scheme, repository: _FakeMarkingScriptRepository(), gradingService: a);
      expect(a.calls, 1);
      // enforced but balance unknown
      MarkingCreditsService.instance.seedForTest(config: MarkingCreditsConfig.fromMap({'mode': 'enforced'}), balance: null);
      final b = _ScriptedGradingService([_ok]);
      await runBatchGrading(scripts: [_buildScript(subjectName: 'M')], scheme: scheme, repository: _FakeMarkingScriptRepository(), gradingService: b);
      expect(b.calls, 1);
    });
  });
}
