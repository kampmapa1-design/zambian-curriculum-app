import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/marking_rubric.dart';
import 'package:zambian_curriculum_app/screens/marking_cohort_structure_screen.dart';

/// Marking Reliability Stage 1 (2026-09-22): the confirmation screen shown
/// before any script in a cohort is marked. These tests are the guarantee
/// that the teacher's actual on-screen decision — not whatever the AI
/// suggested — is what comes back to the caller.
void main() {
  testWidgets('an AI-detected structure is pre-filled, and confirming it unchanged returns the same sections', (tester) async {
    const rubric = MarkingRubric(
      sections: [
        RubricSection(name: 'Section A', questionsToAnswer: null, marksAllocated: 40),
        RubricSection(name: 'Section B', questionsToAnswer: 3, marksAllocated: 60),
      ],
      paperTotalMarks: 100,
      instructionsSummary: 'Answer all of A, any three essays in B.',
    );
    CohortStructureConfirmation? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<CohortStructureConfirmation>(
                MaterialPageRoute(builder: (_) => const MarkingCohortStructureScreen(initialRubric: rubric, subjectName: 'History')),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Section A'), findsOneWidget);
    expect(find.text('Section B'), findsOneWidget);
    expect(find.textContaining('Answer all of A'), findsOneWidget);

    await tester.tap(find.text('Confirm & Start Marking'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    final r = result!.rubric!;
    expect(r.sections.map((s) => s.name), ['Section A', 'Section B']);
    expect(r.sections[0].questionsToAnswer, isNull);
    expect(r.sections[1].questionsToAnswer, 3);
    expect(r.paperTotalMarks, 100);
  });

  testWidgets('the teacher can CORRECT a wrong value before confirming — the correction is what comes back', (tester) async {
    const rubric = MarkingRubric(
      sections: [RubricSection(name: 'Section B', questionsToAnswer: 3, marksAllocated: 900)], // the miskeyed case
      paperTotalMarks: 100,
      instructionsSummary: '',
    );
    CohortStructureConfirmation? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<CohortStructureConfirmation>(
                MaterialPageRoute(builder: (_) => const MarkingCohortStructureScreen(initialRubric: rubric, subjectName: 'History')),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '900'), findsOneWidget);
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '900'), '90');
    await tester.pumpAndSettle();

    // The mismatch warning should now be gone (90 + nothing else == the paper's 100? not exactly,
    // but at least it must not still show the original 900-based warning text).
    expect(find.textContaining('900'), findsNothing);

    await tester.tap(find.text('Confirm & Start Marking'));
    await tester.pumpAndSettle();

    expect(result!.rubric!.sections.single.marksAllocated, 90);
  });

  testWidgets('no structure detected: "No sections" in the app bar confirms a null rubric without opening the editor', (tester) async {
    CohortStructureConfirmation? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<CohortStructureConfirmation>(
                MaterialPageRoute(builder: (_) => const MarkingCohortStructureScreen(initialRubric: null, subjectName: 'History')),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining("didn't find a clear section structure"), findsOneWidget);
    await tester.tap(find.text('No sections'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.rubric, isNull);
  });

  testWidgets('the teacher can manually ADD a section the AI missed entirely, starting from nothing', (tester) async {
    CohortStructureConfirmation? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<CohortStructureConfirmation>(
                MaterialPageRoute(builder: (_) => const MarkingCohortStructureScreen(initialRubric: null, subjectName: 'History')),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add a section'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Section name'), 'Section C');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Confirm & Start Marking'));
    await tester.pumpAndSettle();

    expect(result!.rubric!.sections.single.name, 'Section C');
  });

  testWidgets('a blank section row the teacher never filled in is dropped, not saved as an empty section', (tester) async {
    CohortStructureConfirmation? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<CohortStructureConfirmation>(
                MaterialPageRoute(builder: (_) => const MarkingCohortStructureScreen(initialRubric: null, subjectName: 'History')),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a section'));
    await tester.pumpAndSettle();
    // Never type a name.
    await tester.tap(find.text('Confirm & Start Marking'));
    await tester.pumpAndSettle();

    expect(result!.rubric, isNull); // nothing meaningful was entered -> plain-sum confirmation
  });

  testWidgets('a removed section is excluded from what comes back', (tester) async {
    const rubric = MarkingRubric(
      sections: [RubricSection(name: 'Section A', marksAllocated: 50), RubricSection(name: 'Section B', marksAllocated: 50)],
      paperTotalMarks: 100,
      instructionsSummary: '',
    );
    CohortStructureConfirmation? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<CohortStructureConfirmation>(
                MaterialPageRoute(builder: (_) => const MarkingCohortStructureScreen(initialRubric: rubric, subjectName: 'History')),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm & Start Marking'));
    await tester.pumpAndSettle();

    expect(result!.rubric!.sections, hasLength(1));
    expect(result!.rubric!.sections.single.name, 'Section B');
  });

  testWidgets('backing out (system back) returns null — the caller must not mark anything', (tester) async {
    CohortStructureConfirmation? result = const CohortStructureConfirmation(MarkingRubric(sections: [], instructionsSummary: ''));
    var received = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<CohortStructureConfirmation>(
                MaterialPageRoute(builder: (_) => const MarkingCohortStructureScreen(initialRubric: null, subjectName: 'History')),
              );
              received = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final dynamic navigatorState = tester.state(find.byType(Navigator));
    navigatorState.pop();
    await tester.pumpAndSettle();

    expect(received, isTrue);
    expect(result, isNull);
  });
}
