import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zambian_curriculum_app/models/concise_marking_record.dart';
import 'package:zambian_curriculum_app/models/marking_rubric.dart';
import 'package:zambian_curriculum_app/models/marking_scheme.dart';
import 'package:zambian_curriculum_app/models/marking_script.dart';
import 'package:zambian_curriculum_app/screens/marking_review_comparison_screen.dart';
import 'package:zambian_curriculum_app/services/marking_script_repository.dart';

// A real, minimal, valid 1x1 transparent PNG — decodable by dart:ui's codec
// in a widget test (pure Dart/Skia, no platform channel needed), unlike a
// placeholder byte string.
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _FakePathProviderPlatform extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this.dir);
  final Directory dir;
  @override
  Future<String?> getTemporaryPath() async => dir.path;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
}

class _FakeRepository extends MarkingScriptRepository {
  final List<MarkingScript> updates = [];
  @override
  Future<void> update(MarkingScript script) async => updates.add(script);
}

MarkingScript _script({List<GradedAnswer>? answers, ConciseMarkingRecord? record}) => MarkingScript(
      id: 's1',
      firstName: 'Test',
      surname: 'Candidate',
      gender: CandidateGender.male,
      scriptNumber: 1,
      subjectName: 'History',
      gradeName: 'Grade 10',
      pageFileNames: const ['p1.jpg'],
      capturedAt: DateTime(2026, 9, 22),
      gradedAnswers: answers,
      conciseMarking: record,
    );

GradedAnswer _ans(String label, {double marks = 5, double max = 10, MarkingConfidence conf = MarkingConfidence.high}) => GradedAnswer(
      questionLabel: label,
      maxMarks: max,
      transcribedAnswer: 'answer for $label',
      marksAwarded: marks,
      confidence: conf,
    );

void main() {
  late Directory tempDir;
  late File scriptPage;
  late File questionPaper;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('review_screen_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);
    scriptPage = File('${tempDir.path}/script_page.png')..writeAsBytesSync(_tinyPng);
    questionPaper = File('${tempDir.path}/question_paper.png')..writeAsBytesSync(_tinyPng);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: screen));
    await tester.pumpAndSettle();
  }

  group('question strip (Stage 6) and layout (Stage 11)', () {
    testWidgets('one chip per question, in order; tapping one selects it', (tester) async {
      final script = _script(answers: [_ans('1'), _ans('2'), _ans('3')]);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], repository: _FakeRepository()));

      expect(find.text('Question 1'), findsOneWidget);
      await tester.tap(find.text('2').first);
      await tester.pumpAndSettle();
      expect(find.text('Question 2'), findsOneWidget);
    });

    testWidgets('opens directly on the requested question (Stage 12 routing)', (tester) async {
      final script = _script(answers: [_ans('1'), _ans('2'), _ans('7')]);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], repository: _FakeRepository(), initialQuestionLabel: '7'));
      expect(find.text('Question 7'), findsOneWidget);
    });

    testWidgets('the layout toggle switches between side-by-side and stacked without losing the selection', (tester) async {
      final script = _script(answers: [_ans('1'), _ans('2')]);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], repository: _FakeRepository()));
      expect(find.byIcon(Icons.view_agenda_outlined), findsOneWidget);
      await tester.tap(find.byKey(const Key('layout-toggle')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.view_column_outlined), findsOneWidget);
      expect(find.text('Question 1'), findsOneWidget);
    });

    testWidgets('no graded answers at all: a plain message, not a crash', (tester) async {
      final script = _script(answers: const []);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: const [], repository: _FakeRepository()));
      expect(find.text('No graded questions to review.'), findsOneWidget);
    });
  });

  group('key-pane source (Stage 5 -> Stage 6 wiring)', () {
    testWidgets('a keyed scheme shows the question\'s own expected-answer text', (tester) async {
      final scheme = MarkingScheme(
        id: 'sch', title: 'x', subjectName: 'History', gradeName: 'Grade 10', topicName: 'x',
        questions: const [MarkingSchemeQuestion(label: '1', expectedAnswerOrKeywords: 'Shaka united the clans', maxMarks: 10)],
        createdAt: DateTime(2026),
      );
      final script = _script(answers: [_ans('1')]);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], scheme: scheme, repository: _FakeRepository()));
      expect(find.textContaining('Shaka united the clans'), findsOneWidget);
    });

    testWidgets('no scheme and no question paper: an honest "nothing to compare" message, not a blank/broken pane', (tester) async {
      final script = _script(answers: [_ans('1')]);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], repository: _FakeRepository()));
      expect(find.textContaining('nothing to compare against'), findsOneWidget);
    });

    testWidgets('exactly one question-paper image: shown for every question (an Image pane renders, not the text/none fallback)', (tester) async {
      final script = _script(answers: [_ans('1')]);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], questionPaperFiles: [questionPaper], repository: _FakeRepository()));
      expect(find.textContaining('nothing to compare against'), findsNothing);
      expect(find.byType(Image), findsWidgets);
    });
  });

  group('script pane', () {
    testWidgets('no location for this answer: an honest message instead of guessing', (tester) async {
      final script = _script(answers: [_ans('1')], record: ConciseMarkingRecord(markedAt: DateTime(2026), engine: 'concise', annotations: const [], scoreJson: const {}));
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], repository: _FakeRepository()));
      expect(find.textContaining("wasn't confidently identified"), findsOneWidget);
    });
  });

  group('Stage 9/10 — score overlay and quick correction', () {
    testWidgets('shows the transcribed answer, current mark and confidence for the selected question', (tester) async {
      final script = _script(answers: [_ans('1', marks: 6, max: 10, conf: MarkingConfidence.medium)]);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], repository: _FakeRepository()));
      expect(find.text('answer for 1'), findsOneWidget);
      expect(find.text('medium'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '6'), findsOneWidget);
    });

    testWidgets('saving a corrected mark clamps to maxMarks, persists via the repository, and updates the field shown', (tester) async {
      final repo = _FakeRepository();
      final script = _script(answers: [_ans('1', marks: 5, max: 10)]);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], repository: repo));

      await tester.enterText(find.byKey(const Key('mark-field')), '999'); // way over max
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(repo.updates, hasLength(1));
      final saved = repo.updates.single.gradedAnswers!.single;
      expect(saved.marksAwarded, 10, reason: 'clamped to maxMarks, never left at the entered 999');
      expect(saved.teacherEdited, isTrue);
      expect(find.text('Mark saved.'), findsOneWidget);
    });

    testWidgets('an invalid mark is rejected before anything is saved', (tester) async {
      final repo = _FakeRepository();
      final script = _script(answers: [_ans('1')]);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], repository: repo));

      await tester.enterText(find.byKey(const Key('mark-field')), 'not a number');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(repo.updates, isEmpty);
      expect(find.text('Enter a valid, non-negative mark.'), findsOneWidget);
    });

    testWidgets('the correction is recomputed against the SAME persisted rubric — Stage 2\'s safeguard runs again for free', (tester) async {
      const rubric = MarkingRubric(sections: [], paperTotalMarks: 10, instructionsSummary: '');
      final repo = _FakeRepository();
      final record = ConciseMarkingRecord(
        markedAt: DateTime(2026), engine: 'concise', annotations: const [],
        scoreJson: const {'awardedMarks': 5.0, 'possibleMarks': 10.0, 'percentage': 50.0, 'sections': <Map<String, dynamic>>[]},
        sectionByLabel: const {'1': null}, rubric: rubric,
      );
      final script = _script(answers: [_ans('1', marks: 5, max: 10)], record: record);
      await pump(tester, MarkingReviewComparisonScreen(script: script, scriptPageFiles: [scriptPage], repository: repo));

      await tester.enterText(find.byKey(const Key('mark-field')), '8');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final savedRecord = repo.updates.single.conciseMarking!;
      expect(savedRecord.scoreJson['awardedMarks'], 8.0);
      expect(savedRecord.scoreJson['possibleMarks'], 10.0);
      expect(savedRecord.rubric!.paperTotalMarks, 10);
    });
  });
}
