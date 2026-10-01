// Regression coverage for the timetable engine's typed "you're offline"
// exception (added 2026-09-18) — the timetable counterpart to
// MarkingGradingUnavailable's own offline message. Before this, generating
// a timetable with no connection surfaced whatever raw, opaque error the
// Cloud Functions plugin threw for a dead connection.
//
// Both services are constructed with no Firebase objects at all (their
// Firebase singletons resolve lazily — see TimetableService's own comment),
// and `isOnline` is overridden, so nothing here touches a real Firebase app
// or a real connectivity plugin. Every guarded method must throw BEFORE it
// ever reaches its Cloud Function call — which is exactly what makes this
// testable without one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/independent_timetable_service.dart';
import 'package:zambian_curriculum_app/services/school_service.dart' show SchoolException;
import 'package:zambian_curriculum_app/services/timetable_service.dart';

class _OfflineTimetableService extends TimetableService {
  @override
  Future<bool> get isOnline async => false;
}

class _OfflineIndependentTimetableService extends IndependentTimetableService {
  @override
  Future<bool> get isOnline async => false;
}

void main() {
  group('TimetableService (School Network timetable) offline', () {
    final service = _OfflineTimetableService();

    test('generate throws a friendly TimetableOfflineException, not an opaque plugin error', () async {
      await expectLater(
        service.generate('school1'),
        throwsA(
          isA<TimetableOfflineException>().having((e) => e.message, 'message', contains("You're offline")),
        ),
      );
    });

    test('explainConflicts, parseConstraint and extractFromPhotos are guarded the same way', () async {
      await expectLater(service.explainConflicts('school1'), throwsA(isA<TimetableOfflineException>()));
      await expectLater(
        service.parseConstraint(schoolId: 'school1', text: 'Mr Phiri only teaches mornings'),
        throwsA(isA<TimetableOfflineException>()),
      );
      await expectLater(
        service.extractFromPhotos(schoolId: 'school1', pageFiles: [File('does_not_matter.jpg')]),
        throwsA(isA<TimetableOfflineException>()),
      );
    });

    test('is a SchoolException, so every existing `on SchoolException` call site shows it unchanged', () async {
      await expectLater(service.generate('school1'), throwsA(isA<SchoolException>()));
    });

    test('the message names the action, so a teacher knows what needs a connection', () async {
      try {
        await service.generate('school1');
        fail('expected a TimetableOfflineException');
      } on TimetableOfflineException catch (e) {
        expect(e.message, contains('generate the timetable'));
        expect(e.toString(), e.message, reason: 'toString must equal message — existing screens may use either');
      }
    });
  });

  group('IndependentTimetableService ("Build Timetable for Another School") offline', () {
    final service = _OfflineIndependentTimetableService();

    test('generate throws a friendly TimetableOfflineException', () async {
      await expectLater(
        service.generate('project1'),
        throwsA(
          isA<TimetableOfflineException>().having((e) => e.message, 'message', contains("You're offline")),
        ),
      );
    });

    test('explainConflicts, parseConstraint and extractFromPhotos are guarded the same way', () async {
      await expectLater(service.explainConflicts('project1'), throwsA(isA<TimetableOfflineException>()));
      await expectLater(
        service.parseConstraint(projectId: 'project1', text: 'Mrs Banda is unavailable on Fridays'),
        throwsA(isA<TimetableOfflineException>()),
      );
      await expectLater(
        service.extractFromPhotos(projectId: 'project1', pageFiles: [File('does_not_matter.jpg')]),
        throwsA(isA<TimetableOfflineException>()),
      );
    });

    test('is a SchoolException, so the independent screens\' existing catch sites show it unchanged', () async {
      await expectLater(service.generate('project1'), throwsA(isA<SchoolException>()));
    });
  });
}
