import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/timetable.dart';
import 'package:zambian_curriculum_app/screens/timetable_grid_widget.dart';

/// Timetable Generation — real widget coverage for [TimetableGrid], the
/// shared rendering surface for the class view, By-Teacher view, and
/// export preview. Pure widget, no Firebase — good test-coverage return
/// for the effort.
void main() {
  const assignment = TimetableAssignment(
    classId: 'c1',
    className: 'Grade 8A',
    subjectName: 'Mathematics',
    teacherUid: 'uid1',
    day: 1,
    period: 2,
  );

  testWidgets('an occupied cell shows the subject name and the cellSubtitle callback\'s value', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TimetableGrid(
          assignments: const [assignment],
          periodsPerDay: 4,
          teachingDaysPerWeek: 5,
          cellSubtitle: (a) => 'Mrs Banda',
        ),
      ),
    );
    expect(find.text('Mathematics'), findsOneWidget);
    expect(find.text('Mrs Banda'), findsOneWidget);
  });

  testWidgets('an empty slot shows a dash, not blank/missing content', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TimetableGrid(
          assignments: const [],
          periodsPerDay: 2,
          teachingDaysPerWeek: 2,
          cellSubtitle: (a) => '',
        ),
      ),
    );
    expect(find.text('—'), findsWidgets);
  });

  testWidgets('a locked assignment shows the lock icon, an unlocked one does not', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TimetableGrid(
          assignments: const [assignment],
          periodsPerDay: 4,
          teachingDaysPerWeek: 5,
          cellSubtitle: (a) => '',
        ),
      ),
    );
    expect(find.byIcon(Icons.lock_outline), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: TimetableGrid(
          assignments: [
            TimetableAssignment(
              classId: assignment.classId,
              className: assignment.className,
              subjectName: assignment.subjectName,
              teacherUid: assignment.teacherUid,
              day: assignment.day,
              period: assignment.period,
              locked: true,
            ),
          ],
          periodsPerDay: 4,
          teachingDaysPerWeek: 5,
          cellSubtitle: (a) => '',
        ),
      ),
    );
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('tapping an occupied cell calls onCellTap with that exact assignment', (tester) async {
    TimetableAssignment? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: TimetableGrid(
          assignments: const [assignment],
          periodsPerDay: 4,
          teachingDaysPerWeek: 5,
          cellSubtitle: (a) => '',
          onCellTap: (a) => tapped = a,
        ),
      ),
    );
    await tester.tap(find.text('Mathematics'));
    expect(tapped, assignment);
  });

  testWidgets('with onCellTap null, an occupied cell is not wrapped in an InkWell (read-only, e.g. mobile view)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TimetableGrid(
          assignments: const [assignment],
          periodsPerDay: 4,
          teachingDaysPerWeek: 5,
          cellSubtitle: (a) => '',
        ),
      ),
    );
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('teachingDaysPerWeek is clamped to 7 even if given a larger value (a real defensive-parsing case)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TimetableGrid(
          assignments: const [],
          periodsPerDay: 1,
          teachingDaysPerWeek: 30,
          cellSubtitle: (a) => '',
        ),
      ),
    );
    // 7 day-header cells + 1 "Period" header cell = 8 cells in the header row.
    expect(find.text('Sun'), findsOneWidget); // the 7th day label, proving it stopped at 7
  });
}
