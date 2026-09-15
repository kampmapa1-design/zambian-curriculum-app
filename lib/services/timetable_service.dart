import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/timetable.dart';
import 'school_service.dart' show SchoolException;

/// Timetable Generation, Stage 1 (added 2026-09-14) — client side of the
/// config save path. Writes go through `saveTimetableConfig` (real
/// leadership-only permission check server-side, see index.ts); this
/// class only reads and calls that one function.
class TimetableService {
  TimetableService({FirebaseFunctions? functions, FirebaseFirestore? firestore})
      : _functions = functions ?? FirebaseFunctions.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _configRef(String schoolId) =>
      _firestore.collection('schools').doc(schoolId).collection('timetable').doc('config');

  Stream<TimetableConfig?> watchConfig(String schoolId) {
    return _configRef(schoolId).snapshots().map((doc) => doc.exists ? TimetableConfig.fromMap(doc.data()!) : null);
  }

  Future<TimetableConfig?> getConfig(String schoolId) async {
    final doc = await _configRef(schoolId).get();
    return doc.exists ? TimetableConfig.fromMap(doc.data()!) : null;
  }

  Future<void> saveConfig({required String schoolId, required TimetableConfig config}) async {
    try {
      final callable = _functions.httpsCallable('saveTimetableConfig', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'periodsPerDay': config.periodsPerDay,
        'periodLengthMinutes': config.periodLengthMinutes,
        'teachingDaysPerWeek': config.teachingDaysPerWeek,
        'subjectDefaults': config.subjectDefaults,
        'practicalSubjectsExceptionList': config.practicalSubjectsExceptionList,
        'maxDailyPeriodsPerTeacher': config.maxDailyPeriodsPerTeacher,
      });
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not save the timetable setup.');
    }
  }

  /// Stage 4 — runs the deterministic scheduling engine server-side (see
  /// `generateTimetable`/`generateTimetableSchedule` in index.ts) and
  /// stores the result at `schools/{schoolId}/timetable/generated`. This
  /// call itself only reports counts; [watchGenerated] streams the real
  /// assignments/conflicts once they land.
  Future<({int assignmentCount, int conflictCount})> generate(String schoolId) async {
    try {
      final callable = _functions.httpsCallable('generateTimetable', options: HttpsCallableOptions(timeout: const Duration(seconds: 60)));
      final result = await callable.call<Map<String, dynamic>>({'schoolId': schoolId});
      return (assignmentCount: (result.data['assignmentCount'] as num).toInt(), conflictCount: (result.data['conflictCount'] as num).toInt());
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not generate the timetable.');
    }
  }

  Stream<GeneratedTimetable?> watchGenerated(String schoolId) {
    return _firestore.collection('schools').doc(schoolId).collection('timetable').doc('generated').snapshots().map(
          (doc) => doc.exists ? GeneratedTimetable.fromMap(doc.data()!) : null,
        );
  }

  /// Stage 6 — asks Gemini to explain the conflicts `generate` already
  /// found and write plain-language explanations back onto the generated
  /// doc; [watchGenerated] picks the result up automatically once it
  /// lands, no separate stream needed here.
  Future<void> explainConflicts(String schoolId) async {
    try {
      final callable = _functions.httpsCallable('explainTimetableConflicts', options: HttpsCallableOptions(timeout: const Duration(seconds: 60)));
      await callable.call<Map<String, dynamic>>({'schoolId': schoolId});
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not generate explanations right now.');
    }
  }

  /// Stage 3 — interprets typed text via `parseTimetableConstraint`.
  /// Read-only: this never applies anything by itself, see the model doc
  /// comment on [ParsedTimetableConstraint].
  Future<ParsedTimetableConstraint> parseConstraint({required String schoolId, required String text}) async {
    try {
      final callable = _functions.httpsCallable('parseTimetableConstraint', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({'schoolId': schoolId, 'text': text});
      return ParsedTimetableConstraint.fromMap(result.data.cast<String, dynamic>());
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not interpret that instruction.');
    }
  }

  /// Stage 3 — applies a CONFIRMED availability constraint (the operator
  /// has already reviewed [ParsedTimetableConstraint.summary] and the
  /// resulting slots before this is called).
  Future<void> setTeacherAvailability({required String schoolId, required String teacherUid, required List<String> unavailableSlots}) async {
    try {
      final callable = _functions.httpsCallable('setTeacherAvailability', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({'schoolId': schoolId, 'teacherUid': teacherUid, 'unavailableSlots': unavailableSlots});
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not save that availability constraint.');
    }
  }

  /// Stage 2 — reads a photographed paper timetable via
  /// `extractTimetableFromPhoto`. Read-only: see
  /// [ExtractedTimetable]'s doc comment for why nothing is applied here.
  Future<ExtractedTimetable> extractFromPhotos({required String schoolId, required List<File> pageFiles}) async {
    try {
      final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
      final callable = _functions.httpsCallable('extractTimetableFromPhoto', options: HttpsCallableOptions(timeout: const Duration(seconds: 115)));
      final result = await callable.call<Map<String, dynamic>>({'schoolId': schoolId, 'pageImagesBase64': images});
      return ExtractedTimetable.fromMap(result.data.cast<String, dynamic>());
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not read this timetable.');
    }
  }

  /// Stages 5 & 7 — moves one lesson to a different day/period. The
  /// server re-checks the exact same conflict rules the engine enforces
  /// (see `moveTimetableAssignment` in index.ts) BEFORE writing anything
  /// — a rejected move surfaces as a [SchoolException] with the specific
  /// reason, and nothing changes. A successful move auto-locks the
  /// lesson so a later regenerate won't move it back.
  Future<void> moveAssignment({
    required String schoolId,
    required String classId,
    required String subjectName,
    required String teacherUid,
    required int day,
    required int period,
    required int newDay,
    required int newPeriod,
  }) async {
    try {
      final callable = _functions.httpsCallable('moveTimetableAssignment', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'classId': classId,
        'subjectName': subjectName,
        'teacherUid': teacherUid,
        'day': day,
        'period': period,
        'newDay': newDay,
        'newPeriod': newPeriod,
      });
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not move that lesson.');
    }
  }

  /// Stage 7 — pins/unpins one lesson so a regenerate does (or doesn't)
  /// leave it exactly where it is.
  Future<void> setAssignmentLocked({
    required String schoolId,
    required String classId,
    required String subjectName,
    required String teacherUid,
    required int day,
    required int period,
    required bool locked,
  }) async {
    try {
      final callable = _functions.httpsCallable('setTimetableAssignmentLocked', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'classId': classId,
        'subjectName': subjectName,
        'teacherUid': teacherUid,
        'day': day,
        'period': period,
        'locked': locked,
      });
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not update that lock.');
    }
  }

  /// Every distinct subject name across the school's connected classes —
  /// used to pre-populate [TimetableConfig.subjectDefaults] with
  /// something to adjust, rather than an empty list the operator has to
  /// build from scratch. Reuses School Network's existing `classes` data
  /// (Milestone B1) instead of asking for subjects to be entered twice.
  Future<List<String>> distinctSubjectsAcrossClasses(String schoolId) async {
    final snap = await _firestore.collection('schools').doc(schoolId).collection('classes').get();
    final subjects = <String>{};
    for (final doc in snap.docs) {
      final names = (doc.data()['subjectNames'] as List?)?.whereType<String>() ?? const [];
      subjects.addAll(names);
    }
    final list = subjects.toList()..sort();
    return list;
  }
}
