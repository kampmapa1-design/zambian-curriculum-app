// Real SQLite coverage (2026-09-15) for ReportClassRepository — the Report
// Form Pipeline's roster/Broad-Mark-Sheet backbone. See
// support/sqlite_test_setup.dart for how `flutter test` gets a real,
// disposable SQLite database with no platform channels.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/report_class.dart';
import 'package:zambian_curriculum_app/services/database_helper.dart';
import 'package:zambian_curriculum_app/services/report_class_repository.dart';

import 'support/sqlite_test_setup.dart';

void main() {
  late ReportClassRepository repo;

  setUp(() async {
    await setUpTestDatabase();
    repo = ReportClassRepository(databaseHelper: DatabaseHelper.instance);
  });

  Future<ReportClass> makeClass({
    String schoolName = 'Test School',
    String classGrade = 'Grade 10',
    String term = 'Term 1',
    ReportAssessmentSystem assessmentSystem = ReportAssessmentSystem.standaloneTest,
  }) =>
      repo.createClass(schoolName: schoolName, classGrade: classGrade, term: term, assessmentSystem: assessmentSystem);

  // -------------------------------------------------------------------
  group('classes', () {
    test('createClass trims free-text fields and defaults to standalone-test scoring', () async {
      final c = await repo.createClass(schoolName: '  Kabulonga Girls  ', classGrade: ' Grade 10 ', term: ' Term 1 ');
      expect(c.schoolName, 'Kabulonga Girls');
      expect(c.classGrade, 'Grade 10');
      expect(c.term, 'Term 1');
      expect(c.assessmentSystem, ReportAssessmentSystem.standaloneTest);
      expect(c.backupEmail, isNull);

      final reloaded = await repo.getClass(c.id);
      expect(reloaded, isNotNull);
      expect(reloaded!.schoolName, 'Kabulonga Girls');
    });

    test('getClass returns null for an id that does not exist', () async {
      expect(await repo.getClass(999999), isNull);
    });

    test('listClasses orders most recently created first', () async {
      final a = await makeClass(schoolName: 'A');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = await makeClass(schoolName: 'B');
      final classes = await repo.listClasses();
      expect(classes.map((c) => c.id).toList(), [b.id, a.id]);
    });

    test('confirmCaWeights rejects weights that do not sum to 100', () async {
      final c = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
      expect(
        () => repo.confirmCaWeights(c.id, testWeightPercent: 40, examWeightPercent: 50),
        throwsArgumentError,
      );
    });

    test('confirmCaWeights persists a valid split, which flips hasConfirmedCaWeights on', () async {
      final c = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
      expect(c.hasConfirmedCaWeights, isFalse);
      await repo.confirmCaWeights(c.id, testWeightPercent: 30, examWeightPercent: 70);
      final reloaded = await repo.getClass(c.id);
      expect(reloaded!.hasConfirmedCaWeights, isTrue);
      expect(reloaded.caTestWeightPercent, 30);
      expect(reloaded.caExamWeightPercent, 70);
    });

    test('updateBackupEmail sets and then clears via an empty string', () async {
      final c = await makeClass();
      await repo.updateBackupEmail(c.id, 'teacher@example.com');
      expect((await repo.getClass(c.id))!.backupEmail, 'teacher@example.com');
      await repo.updateBackupEmail(c.id, '   ');
      expect((await repo.getClass(c.id))!.backupEmail, isNull);
    });

    test('setFirestoreClassId links a class to a School Network registry entry', () async {
      final c = await makeClass();
      await repo.setFirestoreClassId(c.id, 'school1_class9');
      expect((await repo.getClass(c.id))!.firestoreClassId, 'school1_class9');
    });

    test('markReportFormsCompleted stamps completion, which scores remain editable after', () async {
      final c = await makeClass();
      expect(c.isReportFormsCompleted, isFalse);
      await repo.markReportFormsCompleted(c.id);
      final reloaded = await repo.getClass(c.id);
      expect(reloaded!.isReportFormsCompleted, isTrue);
      expect(reloaded.reportFormsCompletedAt, isNotNull);
    });

    test('deleteClass cascades to its learners, subjects, and scores', () async {
      final c = await makeClass();
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
      await repo.setScore(learnerId: learner.id, subject: subject, score: 80);

      await repo.deleteClass(c.id);

      expect(await repo.getClass(c.id), isNull);
      expect(await repo.listLearners(c.id), isEmpty);
      expect(await repo.listSubjects(c.id), isEmpty);
      expect(await repo.getScore(learner.id, subject.id), isNull);
    });
  });

  // -------------------------------------------------------------------
  group('learners / roster', () {
    test('addLearner assigns sequential roster order starting at 1', () async {
      final c = await makeClass();
      final l1 = await repo.addLearner(c.id, 'Chanda Mwansa');
      final l2 = await repo.addLearner(c.id, 'Bwalya Phiri');
      expect(l1.rosterOrder, 1);
      expect(l2.rosterOrder, 2);
    });

    test('addLearner refuses past the 140-learner cap', () async {
      final c = await makeClass();
      for (var i = 0; i < ReportClassRepository.maxLearners; i++) {
        await repo.addLearner(c.id, 'Learner $i');
      }
      expect(await repo.listLearners(c.id), hasLength(ReportClassRepository.maxLearners));
      expect(() => repo.addLearner(c.id, 'One too many'), throwsStateError);
    });

    test('renameLearner corrects the name without touching that learner\'s scores', () async {
      final c = await makeClass();
      final learner = await repo.addLearner(c.id, 'Chnisha Banda');
      final subject = await repo.getOrCreateSubject(c.id, 'English');
      await repo.setScore(learnerId: learner.id, subject: subject, score: 65);

      await repo.renameLearner(learner.id, 'Chanisha Banda');

      final roster = await repo.listLearners(c.id);
      expect(roster.single.fullName, 'Chanisha Banda');
      expect((await repo.getScore(learner.id, subject.id))!.score, 65);
    });

    test('deleteLearner removes only that learner and their own scores', () async {
      final c = await makeClass();
      final keep = await repo.addLearner(c.id, 'Keep Me');
      final remove = await repo.addLearner(c.id, 'Remove Me');
      final subject = await repo.getOrCreateSubject(c.id, 'Science');
      await repo.setScore(learnerId: keep.id, subject: subject, score: 70);
      await repo.setScore(learnerId: remove.id, subject: subject, score: 40);

      await repo.deleteLearner(remove.id);

      final roster = await repo.listLearners(c.id);
      expect(roster.map((l) => l.id), [keep.id]);
      expect((await repo.getScore(keep.id, subject.id))!.score, 70);
      expect(await repo.getScore(remove.id, subject.id), isNull);
    });

    test('updateGuardianContact sets both fields, then clears each via an empty string', () async {
      final c = await makeClass();
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      await repo.updateGuardianContact(learner.id, email: 'guardian@example.com', phone: '0977123456');
      var reloaded = (await repo.listLearners(c.id)).single;
      expect(reloaded.guardianEmail, 'guardian@example.com');
      expect(reloaded.guardianPhone, '0977123456');

      await repo.updateGuardianContact(learner.id, email: '  ', phone: null);
      reloaded = (await repo.listLearners(c.id)).single;
      expect(reloaded.guardianEmail, isNull);
      expect(reloaded.guardianPhone, isNull);
    });

    group('matchNamesAgainstRoster', () {
      test('an empty roster is established by the first upload — every extracted name becomes a new learner', () async {
        final c = await makeClass();
        final matches = await repo.matchNamesAgainstRoster(c.id, const [
          (name: 'Chanda Mwansa', score: '78'),
          (name: 'Bwalya Phiri', score: '65'),
        ]);
        expect(matches, hasLength(2));
        expect(matches.every((m) => m.isMatched), isTrue);
        expect(await repo.listLearners(c.id), hasLength(2));
      });

      test('a later upload matches an existing roster entry by exact normalized name', () async {
        final c = await makeClass();
        final learner = await repo.addLearner(c.id, 'Chanda   Mwansa'); // extra internal whitespace
        final matches = await repo.matchNamesAgainstRoster(c.id, const [
          (name: '  chanda mwansa  ', score: '80'),
        ]);
        expect(matches.single.matchedLearner?.id, learner.id);
        // Never silently duplicated the roster with a second, near-identical entry.
        expect(await repo.listLearners(c.id), hasLength(1));
      });

      test('an unmatched, wildly different name gets neither a match nor a closest-match suggestion', () async {
        final c = await makeClass();
        await repo.addLearner(c.id, 'Chanda Mwansa');
        final matches = await repo.matchNamesAgainstRoster(c.id, const [
          (name: 'Someone Completely Different', score: '50'),
        ]);
        expect(matches.single.matchedLearner, isNull);
        expect(matches.single.closestMatch, isNull);
      });

      test('an unmatched but close (plausible OCR misread) name offers a one-tap closest-match suggestion', () async {
        final c = await makeClass();
        final learner = await repo.addLearner(c.id, 'Chanisha Banda');
        final matches = await repo.matchNamesAgainstRoster(c.id, const [
          (name: 'Chnisha Banda', score: '60'), // one transposed/dropped letter
        ]);
        expect(matches.single.matchedLearner, isNull);
        expect(matches.single.closestMatch?.id, learner.id);
      });

      test('never auto-links on the closest match — matchedLearner stays null even when a suggestion exists', () async {
        final c = await makeClass();
        await repo.addLearner(c.id, 'Chanisha Banda');
        final matches = await repo.matchNamesAgainstRoster(c.id, const [
          (name: 'Chnisha Banda', score: '60'),
        ]);
        expect(matches.single.isMatched, isFalse);
      });
    });
  });

  // -------------------------------------------------------------------
  group('subjects', () {
    test('getOrCreateSubject reuses an existing subject with the same normalized name', () async {
      final c = await makeClass();
      final first = await repo.getOrCreateSubject(c.id, 'Mathematics');
      final second = await repo.getOrCreateSubject(c.id, '  mathematics  ');
      expect(second.id, first.id);
      expect(await repo.listSubjects(c.id), hasLength(1));
    });

    test('getOrCreateSubject assigns increasing sequence numbers to distinct subjects', () async {
      final c = await makeClass();
      final s1 = await repo.getOrCreateSubject(c.id, 'Mathematics');
      final s2 = await repo.getOrCreateSubject(c.id, 'English');
      expect(s1.sequenceNumber, 1);
      expect(s2.sequenceNumber, 2);
    });

    test('getOrCreateSubject refuses past the 12-subject cap', () async {
      final c = await makeClass();
      for (var i = 0; i < ReportClassRepository.maxSubjects; i++) {
        await repo.getOrCreateSubject(c.id, 'Subject $i');
      }
      expect(() => repo.getOrCreateSubject(c.id, 'One too many'), throwsStateError);
    });

    test('createCompositeSubject combines two real parts from the same class', () async {
      final c = await makeClass();
      final physics = await repo.getOrCreateSubject(c.id, 'Physics');
      final chemistry = await repo.getOrCreateSubject(c.id, 'Chemistry');
      final science = await repo.createCompositeSubject(classId: c.id, name: 'Science', partA: physics, partB: chemistry);
      expect(science.isComposite, isTrue);
      expect(science.compositePartAId, physics.id);
      expect(science.compositePartBId, chemistry.id);
    });

    test('createCompositeSubject rejects a part belonging to a different class', () async {
      final c1 = await makeClass(schoolName: 'School 1');
      final c2 = await makeClass(schoolName: 'School 2');
      final physics = await repo.getOrCreateSubject(c1.id, 'Physics');
      final chemistry = await repo.getOrCreateSubject(c2.id, 'Chemistry');
      expect(
        () => repo.createCompositeSubject(classId: c1.id, name: 'Science', partA: physics, partB: chemistry),
        throwsArgumentError,
      );
    });

    test('createCompositeSubject rejects building a composite from another composite', () async {
      final c = await makeClass();
      final physics = await repo.getOrCreateSubject(c.id, 'Physics');
      final chemistry = await repo.getOrCreateSubject(c.id, 'Chemistry');
      final science = await repo.createCompositeSubject(classId: c.id, name: 'Science', partA: physics, partB: chemistry);
      final biology = await repo.getOrCreateSubject(c.id, 'Biology');
      expect(
        () => repo.createCompositeSubject(classId: c.id, name: 'Double Science', partA: science, partB: biology),
        throwsArgumentError,
      );
    });
  });

  // -------------------------------------------------------------------
  group('scores', () {
    test('setScore rejects a direct write to a composite subject', () async {
      final c = await makeClass();
      final physics = await repo.getOrCreateSubject(c.id, 'Physics');
      final chemistry = await repo.getOrCreateSubject(c.id, 'Chemistry');
      final science = await repo.createCompositeSubject(classId: c.id, name: 'Science', partA: physics, partB: chemistry);
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      expect(() => repo.setScore(learnerId: learner.id, subject: science, score: 50), throwsArgumentError);
    });

    test('setScore preserves an already-stored C.A. component rather than wiping it', () async {
      final c = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
      await repo.confirmCaWeights(c.id, testWeightPercent: 40, examWeightPercent: 60);
      final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      await repo.setComponentScore(
        learnerId: learner.id,
        subject: subject,
        reportClass: (await repo.getClass(c.id))!,
        component: ReportCaComponent.test,
        value: 70,
      );
      await repo.setScore(learnerId: learner.id, subject: subject, score: 55, comment: 'manual override');
      final stored = await repo.getScore(learner.id, subject.id);
      expect(stored!.caTestScore, 70);
    });

    test('setComponentScore never guesses a missing component as zero — score stays null until both exist', () async {
      final c = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
      await repo.confirmCaWeights(c.id, testWeightPercent: 40, examWeightPercent: 60);
      final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      final reportClass = (await repo.getClass(c.id))!;

      await repo.setComponentScore(
        learnerId: learner.id,
        subject: subject,
        reportClass: reportClass,
        component: ReportCaComponent.test,
        value: 80,
      );
      expect((await repo.getScore(learner.id, subject.id))!.score, isNull);

      await repo.setComponentScore(
        learnerId: learner.id,
        subject: subject,
        reportClass: reportClass,
        component: ReportCaComponent.exam,
        value: 60,
      );
      final finalScore = (await repo.getScore(learner.id, subject.id))!.score;
      expect(finalScore, closeTo(80 * 0.4 + 60 * 0.6, 0.0001));
    });

    test('setComponentScore never computes a final score before C.A. weights are confirmed', () async {
      final c = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
      final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      final reportClass = (await repo.getClass(c.id))!;
      await repo.setComponentScore(
          learnerId: learner.id, subject: subject, reportClass: reportClass, component: ReportCaComponent.test, value: 80);
      await repo.setComponentScore(
          learnerId: learner.id, subject: subject, reportClass: reportClass, component: ReportCaComponent.exam, value: 60);
      expect((await repo.getScore(learner.id, subject.id))!.score, isNull);
    });

    test('setComment only touches comment/commentSource, leaving score and C.A. components untouched', () async {
      final c = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
      await repo.confirmCaWeights(c.id, testWeightPercent: 50, examWeightPercent: 50);
      final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      final reportClass = (await repo.getClass(c.id))!;
      await repo.setComponentScore(
          learnerId: learner.id, subject: subject, reportClass: reportClass, component: ReportCaComponent.test, value: 80);
      await repo.setComponentScore(
          learnerId: learner.id, subject: subject, reportClass: reportClass, component: ReportCaComponent.exam, value: 60);

      await repo.setComment(learnerId: learner.id, subject: subject, comment: 'Good progress', commentSource: ReportCommentSource.manual);

      final stored = await repo.getScore(learner.id, subject.id);
      expect(stored!.comment, 'Good progress');
      expect(stored.caTestScore, 80);
      expect(stored.caExamScore, 60);
      expect(stored.score, closeTo(70, 0.0001));
    });

    group('edited-after-completion flagging', () {
      test('a write before completion never gets flagged', () async {
        final c = await makeClass();
        final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
        final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
        await repo.setScore(learnerId: learner.id, subject: subject, score: 80);
        expect((await repo.getScore(learner.id, subject.id))!.editedAfterCompletionAt, isNull);
      });

      test('a write after completion is flagged with a real timestamp', () async {
        final c = await makeClass();
        final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
        final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
        await repo.setScore(learnerId: learner.id, subject: subject, score: 80);
        await repo.markReportFormsCompleted(c.id);

        await repo.setScore(learnerId: learner.id, subject: subject, score: 85);

        expect((await repo.getScore(learner.id, subject.id))!.editedAfterCompletionAt, isNotNull);
      });

      test('once flagged, later writes keep re-stamping — never clear the flag back to null', () async {
        final c = await makeClass();
        final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
        final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
        await repo.setScore(learnerId: learner.id, subject: subject, score: 80);
        await repo.markReportFormsCompleted(c.id);
        await repo.setScore(learnerId: learner.id, subject: subject, score: 85);
        final firstStamp = (await repo.getScore(learner.id, subject.id))!.editedAfterCompletionAt!;

        await Future<void>.delayed(const Duration(milliseconds: 5));
        await repo.setScore(learnerId: learner.id, subject: subject, score: 90);
        final secondStamp = (await repo.getScore(learner.id, subject.id))!.editedAfterCompletionAt!;

        expect(secondStamp.isAfter(firstStamp), isTrue);
      });

      test('setComponentScore and setComment each independently flag a post-completion write', () async {
        final c = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
        await repo.confirmCaWeights(c.id, testWeightPercent: 50, examWeightPercent: 50);
        final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
        final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
        await repo.markReportFormsCompleted(c.id);
        final reportClass = (await repo.getClass(c.id))!;

        await repo.setComponentScore(
            learnerId: learner.id, subject: subject, reportClass: reportClass, component: ReportCaComponent.test, value: 70);
        expect((await repo.getScore(learner.id, subject.id))!.editedAfterCompletionAt, isNotNull);

        // setComment on a fresh (never-flagged) plain subject, also after completion.
        final subject2 = await repo.getOrCreateSubject(c.id, 'English');
        await repo.setComment(learnerId: learner.id, subject: subject2, comment: 'Note');
        expect((await repo.getScore(learner.id, subject2.id))!.editedAfterCompletionAt, isNotNull);
      });
    });

    group('scoreFor / composite subjects', () {
      test('a composite subject\'s score is always the live sum of its two parts, never stored directly', () async {
        final c = await makeClass();
        final physics = await repo.getOrCreateSubject(c.id, 'Physics');
        final chemistry = await repo.getOrCreateSubject(c.id, 'Chemistry');
        final science = await repo.createCompositeSubject(classId: c.id, name: 'Science', partA: physics, partB: chemistry);
        final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
        await repo.setScore(learnerId: learner.id, subject: physics, score: 30);
        await repo.setScore(learnerId: learner.id, subject: chemistry, score: 25);

        expect(await repo.scoreFor(learner.id, science), 55);
      });

      test('a composite subject never guesses a missing part as zero', () async {
        final c = await makeClass();
        final physics = await repo.getOrCreateSubject(c.id, 'Physics');
        final chemistry = await repo.getOrCreateSubject(c.id, 'Chemistry');
        final science = await repo.createCompositeSubject(classId: c.id, name: 'Science', partA: physics, partB: chemistry);
        final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
        await repo.setScore(learnerId: learner.id, subject: physics, score: 30);
        // chemistry never scored

        expect(await repo.scoreFor(learner.id, science), isNull);
      });

      test('recomputes live — changing a part\'s score changes the composite immediately', () async {
        final c = await makeClass();
        final physics = await repo.getOrCreateSubject(c.id, 'Physics');
        final chemistry = await repo.getOrCreateSubject(c.id, 'Chemistry');
        final science = await repo.createCompositeSubject(classId: c.id, name: 'Science', partA: physics, partB: chemistry);
        final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
        await repo.setScore(learnerId: learner.id, subject: physics, score: 30);
        await repo.setScore(learnerId: learner.id, subject: chemistry, score: 25);
        expect(await repo.scoreFor(learner.id, science), 55);

        await repo.setScore(learnerId: learner.id, subject: physics, score: 40);
        expect(await repo.scoreFor(learner.id, science), 65);
      });
    });
  });

  // -------------------------------------------------------------------
  group('class position / rank', () {
    test('aggregateScores counts a composite subject once, never double-counting its two parts', () async {
      final c = await makeClass();
      final physics = await repo.getOrCreateSubject(c.id, 'Physics');
      final chemistry = await repo.getOrCreateSubject(c.id, 'Chemistry');
      await repo.createCompositeSubject(classId: c.id, name: 'Science', partA: physics, partB: chemistry);
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      await repo.setScore(learnerId: learner.id, subject: physics, score: 10);
      await repo.setScore(learnerId: learner.id, subject: chemistry, score: 20);

      final aggregates = await repo.aggregateScores(c.id);
      // Composite (30) counted once — not 10 + 20 + 30 = 60.
      expect(aggregates[learner.id], 30);
    });

    test('a learner with no scores anywhere is excluded (null), never scored as zero', () async {
      final c = await makeClass();
      await repo.getOrCreateSubject(c.id, 'Mathematics');
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      final aggregates = await repo.aggregateScores(c.id);
      expect(aggregates[learner.id], isNull);
    });

    test('classPositions uses competition ranking — a tie shares a position, the next skips ahead', () async {
      final c = await makeClass();
      final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
      final first = await repo.addLearner(c.id, 'First');
      final tiedA = await repo.addLearner(c.id, 'TiedA');
      final tiedB = await repo.addLearner(c.id, 'TiedB');
      final last = await repo.addLearner(c.id, 'Last');
      await repo.setScore(learnerId: first.id, subject: subject, score: 90);
      await repo.setScore(learnerId: tiedA.id, subject: subject, score: 70);
      await repo.setScore(learnerId: tiedB.id, subject: subject, score: 70);
      await repo.setScore(learnerId: last.id, subject: subject, score: 50);

      final positions = await repo.classPositions(c.id);
      expect(positions[first.id], 1);
      expect(positions[tiedA.id], 2);
      expect(positions[tiedB.id], 2);
      expect(positions[last.id], 4);
    });

    test('subjectPositions ranks within one subject alone, excluding a learner with no score for it', () async {
      final c = await makeClass();
      final math = await repo.getOrCreateSubject(c.id, 'Mathematics');
      final english = await repo.getOrCreateSubject(c.id, 'English');
      final a = await repo.addLearner(c.id, 'A');
      final b = await repo.addLearner(c.id, 'B');
      await repo.setScore(learnerId: a.id, subject: math, score: 90);
      await repo.setScore(learnerId: b.id, subject: math, score: 60);
      await repo.setScore(learnerId: a.id, subject: english, score: 40);
      // b never scored in english

      final mathPositions = await repo.subjectPositions(c.id, math);
      expect(mathPositions, {a.id: 1, b.id: 2});
      final englishPositions = await repo.subjectPositions(c.id, english);
      expect(englishPositions.containsKey(b.id), isFalse);
      expect(englishPositions[a.id], 1);
    });
  });

  // -------------------------------------------------------------------
  group('Broad Mark Sheet', () {
    test('loadBroadMarkSheet throws for a class that no longer exists', () async {
      expect(() => repo.loadBroadMarkSheet(999999), throwsStateError);
    });

    test('loadBroadMarkSheet assembles learners, subjects, and every stored score keyed for lookup', () async {
      final c = await makeClass();
      final subject = await repo.getOrCreateSubject(c.id, 'Mathematics');
      final learner = await repo.addLearner(c.id, 'Chanda Mwansa');
      await repo.setScore(learnerId: learner.id, subject: subject, score: 77);

      final sheet = await repo.loadBroadMarkSheet(c.id);
      expect(sheet.learners.single.id, learner.id);
      expect(sheet.subjects.single.id, subject.id);
      expect(sheet.scoreRowFor(learner.id, subject.id)?.score, 77);
    });
  });

  // -------------------------------------------------------------------
  group('consolidateClasses', () {
    test('refuses fewer than 2 distinct source classes', () async {
      final c = await makeClass();
      expect(() => repo.consolidateClasses(sourceClassIds: [c.id], schoolName: 'S', classGrade: 'G', term: 'T'),
          throwsArgumentError);
    });

    test('refuses mixing a standalone-test class with a Continuous Assessment class', () async {
      final c1 = await makeClass(assessmentSystem: ReportAssessmentSystem.standaloneTest);
      final c2 = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
      expect(
        () => repo.consolidateClasses(sourceClassIds: [c1.id, c2.id], schoolName: 'S', classGrade: 'G', term: 'T'),
        throwsStateError,
      );
    });

    test('refuses two C.A. classes with different confirmed weightings', () async {
      final c1 = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
      final c2 = await makeClass(assessmentSystem: ReportAssessmentSystem.continuousAssessment);
      await repo.confirmCaWeights(c1.id, testWeightPercent: 40, examWeightPercent: 60);
      await repo.confirmCaWeights(c2.id, testWeightPercent: 30, examWeightPercent: 70);
      expect(
        () => repo.consolidateClasses(sourceClassIds: [c1.id, c2.id], schoolName: 'S', classGrade: 'G', term: 'T'),
        throwsStateError,
      );
    });

    test('unions rosters by exact normalized name, alphabetically ordered, never double-counting a shared learner', () async {
      final c1 = await makeClass(schoolName: 'Session 1');
      final c2 = await makeClass(schoolName: 'Session 2');
      await repo.addLearner(c1.id, 'Chanda Mwansa');
      await repo.addLearner(c1.id, 'Bwalya Phiri');
      await repo.addLearner(c2.id, 'chanda   mwansa'); // same learner, different session's spelling/casing
      await repo.addLearner(c2.id, 'Amina Zulu');

      final merged =
          await repo.consolidateClasses(sourceClassIds: [c1.id, c2.id], schoolName: 'Merged', classGrade: 'G10', term: 'T1');
      final names = (await repo.listLearners(merged.id)).map((l) => l.fullName).toList();
      expect(names, ['Amina Zulu', 'Bwalya Phiri', 'Chanda Mwansa']);
    });

    test('source classes are left completely untouched by consolidation', () async {
      final c1 = await makeClass(schoolName: 'Session 1');
      final c2 = await makeClass(schoolName: 'Session 2');
      final l1 = await repo.addLearner(c1.id, 'Chanda Mwansa');
      await repo.addLearner(c2.id, 'Bwalya Phiri');
      final subject = await repo.getOrCreateSubject(c1.id, 'Mathematics');
      await repo.setScore(learnerId: l1.id, subject: subject, score: 88);

      await repo.consolidateClasses(sourceClassIds: [c1.id, c2.id], schoolName: 'Merged', classGrade: 'G10', term: 'T1');

      expect(await repo.getClass(c1.id), isNotNull);
      expect(await repo.listLearners(c1.id), hasLength(1));
      expect((await repo.getScore(l1.id, subject.id))!.score, 88);
    });

    test('when the same learner+subject was scored in more than one source, the most recently updated wins', () async {
      final c1 = await makeClass(schoolName: 'Session 1');
      final c2 = await makeClass(schoolName: 'Session 2');
      await repo.addLearner(c1.id, 'Chanda Mwansa');
      await repo.addLearner(c2.id, 'Chanda Mwansa');
      final subject1 = await repo.getOrCreateSubject(c1.id, 'Mathematics');
      final subject2 = await repo.getOrCreateSubject(c2.id, 'Mathematics');
      final learner1 = (await repo.listLearners(c1.id)).single;
      final learner2 = (await repo.listLearners(c2.id)).single;

      await repo.setScore(learnerId: learner1.id, subject: subject1, score: 50);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.setScore(learnerId: learner2.id, subject: subject2, score: 90); // written later — should win

      final merged =
          await repo.consolidateClasses(sourceClassIds: [c1.id, c2.id], schoolName: 'Merged', classGrade: 'G10', term: 'T1');
      final mergedLearner = (await repo.listLearners(merged.id)).single;
      final mergedSubject = (await repo.listSubjects(merged.id)).single;
      expect((await repo.getScore(mergedLearner.id, mergedSubject.id))!.score, 90);
    });

    test('rebuilds a composite subject from its NEW-class parts, never copying the old part ids verbatim', () async {
      final c1 = await makeClass(schoolName: 'Session 1');
      final c2 = await makeClass(schoolName: 'Session 2');
      final physics1 = await repo.getOrCreateSubject(c1.id, 'Physics');
      final chemistry1 = await repo.getOrCreateSubject(c1.id, 'Chemistry');
      await repo.createCompositeSubject(classId: c1.id, name: 'Science', partA: physics1, partB: chemistry1);
      final learner1 = await repo.addLearner(c1.id, 'Chanda Mwansa');
      await repo.setScore(learnerId: learner1.id, subject: physics1, score: 20);
      await repo.setScore(learnerId: learner1.id, subject: chemistry1, score: 15);
      await repo.addLearner(c2.id, 'Bwalya Phiri');

      final merged =
          await repo.consolidateClasses(sourceClassIds: [c1.id, c2.id], schoolName: 'Merged', classGrade: 'G10', term: 'T1');
      final mergedSubjects = await repo.listSubjects(merged.id);
      final mergedScience = mergedSubjects.firstWhere((s) => s.name == 'Science');
      final mergedPhysics = mergedSubjects.firstWhere((s) => s.name == 'Physics');
      final mergedChemistry = mergedSubjects.firstWhere((s) => s.name == 'Chemistry');
      expect(mergedScience.compositePartAId, mergedPhysics.id);
      expect(mergedScience.compositePartBId, mergedChemistry.id);
      expect(mergedScience.compositePartAId, isNot(physics1.id)); // a genuinely new id in the new class

      final mergedLearner =
          (await repo.listLearners(merged.id)).firstWhere((l) => l.fullName == 'Chanda Mwansa');
      expect(await repo.scoreFor(mergedLearner.id, mergedScience), 35);
    });
  });

  // -------------------------------------------------------------------
  group('ReportClass.copyWith', () {
    test('preserves reportFormsCompletedAt when not explicitly overridden by an unrelated copyWith call', () async {
      final c = await makeClass();
      await repo.markReportFormsCompleted(c.id);
      final completed = (await repo.getClass(c.id))!;
      expect(completed.reportFormsCompletedAt, isNotNull);

      final updated = completed.copyWith(backupEmail: 'new@example.com');
      expect(updated.reportFormsCompletedAt, completed.reportFormsCompletedAt);
      expect(updated.backupEmail, 'new@example.com');
    });

    test('preserves every other field not explicitly overridden', () async {
      final base = ReportClass(
        id: 1,
        schoolName: 'School',
        classGrade: 'Grade 10',
        term: 'Term 1',
        createdAt: DateTime(2026, 1, 1),
        assessmentSystem: ReportAssessmentSystem.continuousAssessment,
        caTestWeightPercent: 40,
        caExamWeightPercent: 60,
        backupEmail: 'a@example.com',
        firestoreClassId: 'fc1',
      );
      final copy = base.copyWith(backupEmail: 'b@example.com');
      expect(copy.id, 1);
      expect(copy.schoolName, 'School');
      expect(copy.assessmentSystem, ReportAssessmentSystem.continuousAssessment);
      expect(copy.caTestWeightPercent, 40);
      expect(copy.caExamWeightPercent, 60);
      expect(copy.firestoreClassId, 'fc1');
      expect(copy.backupEmail, 'b@example.com');
    });
  });
}
