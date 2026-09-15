import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zambian_curriculum_app/screens/first_launch_screen.dart';
import 'package:zambian_curriculum_app/services/teacher_profile_repository.dart';

/// Home Assignment epic, Stage 1 — real widget coverage for the
/// REVISED FirstLaunchScreen (role-only, no phone/OTP step at all — see
/// that file's own doc comment for why it was cut down). This is a good
/// widget-test candidate precisely because it depends on nothing but
/// SharedPreferences now, unlike almost every other screen in this app
/// which reaches for FirebaseAuth/Firestore directly.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Continue is disabled until a role is picked', (tester) async {
    await tester.pumpWidget(MaterialApp(home: FirstLaunchScreen(onDone: (_) {})));

    final continueButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));
    expect(continueButton.onPressed, isNull);
  });

  testWidgets('both Teacher and Pupil options are shown', (tester) async {
    await tester.pumpWidget(MaterialApp(home: FirstLaunchScreen(onDone: (_) {})));
    expect(find.text('Teacher'), findsOneWidget);
    expect(find.text('Pupil'), findsOneWidget);
  });

  testWidgets('picking Pupil enables Continue, and tapping it saves the role and calls onDone', (tester) async {
    AccountRole? reported;
    await tester.pumpWidget(MaterialApp(home: FirstLaunchScreen(onDone: (role) => reported = role)));

    await tester.tap(find.text('Pupil'));
    await tester.pump();

    final continueButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));
    expect(continueButton.onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pump(); // start the async _finish()
    await tester.pump(); // let TeacherProfileRepository's load/save futures resolve

    expect(reported, AccountRole.pupil);

    final saved = await TeacherProfileRepository().load();
    expect(saved.role, AccountRole.pupil, reason: 'the role must actually persist locally, not just be reported via the callback');
  });

  testWidgets('picking Teacher then switching to Pupil keeps only the last choice selected', (tester) async {
    await tester.pumpWidget(MaterialApp(home: FirstLaunchScreen(onDone: (_) {})));

    await tester.tap(find.text('Teacher'));
    await tester.pump();
    await tester.tap(find.text('Pupil'));
    await tester.pump();

    // Both check icons would only appear if selection state leaked between
    // cards — exactly one "check_circle" should be showing.
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
