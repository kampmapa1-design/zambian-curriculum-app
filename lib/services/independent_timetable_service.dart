import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/independent_timetable_project.dart';
import '../models/timetable.dart';
import 'school_service.dart' show SchoolException;

/// "Build Timetable for Another School" (added 2026-09-16, per explicit
/// request — "This function should make it possible for this component
/// of the software to build a timetable from the scratch for a
/// different institution altogether... not in any way connected to the
/// subscribed school"). A parallel, fully independent counterpart to
/// [TimetableService]: same deterministic scheduling engine
/// (`generateTimetableSchedule` in firebase/functions/src/index.ts is
/// imported unchanged by `generateIndependentTimetable` — zero
/// duplication of the actual algorithm), same [TimetableConfig]/
/// [GeneratedTimetable] shapes, but against a separate
/// `independentTimetableProjects/{id}` collection where every doc is
/// owned solely by the creating uid (enforced server-side on every
/// call) — no School Network membership, no real registered teacher
/// roster, no subscription-tier gate, so a teacher can draft a timetable
/// for any other institution without it ever touching their own real
/// subscribed school's data.
class IndependentTimetableService {
  IndependentTimetableService({FirebaseFunctions? functions, FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _functions = functions ?? FirebaseFunctions.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CollectionReference<Map<String, dynamic>> get _projects => _firestore.collection('independentTimetableProjects');

  Stream<List<IndependentTimetableProject>> watchMyProjects() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value(const []);
    return _projects.where('ownerUid', isEqualTo: uid).snapshots().map(
          (snap) => snap.docs.map((d) => IndependentTimetableProject.fromMap(d.id, d.data())).toList()
            ..sort((a, b) => a.institutionName.toLowerCase().compareTo(b.institutionName.toLowerCase())),
        );
  }

  Future<IndependentTimetableProject> createProject(String institutionName) async {
    try {
      final callable = _functions.httpsCallable('createIndependentTimetableProject', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({'institutionName': institutionName});
      return IndependentTimetableProject(id: result.data['projectId'] as String, institutionName: institutionName.trim());
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not create this timetable project.');
    }
  }

  Future<void> deleteProject(String projectId) async {
    try {
      final callable = _functions.httpsCallable('deleteIndependentTimetableProject', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({'projectId': projectId});
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not delete this timetable project.');
    }
  }

  DocumentReference<Map<String, dynamic>> _configRef(String projectId) => _projects.doc(projectId).collection('timetable').doc('config');

  Stream<TimetableConfig?> watchConfig(String projectId) =>
      _configRef(projectId).snapshots().map((doc) => doc.exists ? TimetableConfig.fromMap(doc.data()!) : null);

  Future<TimetableConfig?> getConfig(String projectId) async {
    final doc = await _configRef(projectId).get();
    return doc.exists ? TimetableConfig.fromMap(doc.data()!) : null;
  }

  Future<void> saveConfig({required String projectId, required TimetableConfig config}) async {
    try {
      final callable = _functions.httpsCallable('saveIndependentTimetableConfig', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'projectId': projectId,
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

  Stream<List<IndependentTimetableClass>> watchClasses(String projectId) => _projects
      .doc(projectId)
      .collection('classes')
      .snapshots()
      .map((snap) => snap.docs.map((d) => IndependentTimetableClass.fromMap(d.id, d.data())).toList()
        ..sort((a, b) => a.classGrade.toLowerCase().compareTo(b.classGrade.toLowerCase())));

  Future<List<String>> distinctSubjectsAcrossClasses(String projectId) async {
    final snap = await _projects.doc(projectId).collection('classes').get();
    final subjects = <String>{};
    for (final doc in snap.docs) {
      final names = (doc.data()['subjectNames'] as List?)?.whereType<String>() ?? const [];
      subjects.addAll(names);
    }
    final list = subjects.toList()..sort();
    return list;
  }

  Future<String> saveClass({
    required String projectId,
    String? classId,
    required String classGrade,
    required List<String> subjectNames,
    required Map<String, String> subjectTeacherNames,
  }) async {
    try {
      final callable = _functions.httpsCallable('saveIndependentTimetableClass', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({
        'projectId': projectId,
        if (classId != null) 'classId': classId,
        'classGrade': classGrade,
        'subjectNames': subjectNames,
        'subjectTeacherNames': subjectTeacherNames,
      });
      return result.data['classId'] as String;
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not save this class.');
    }
  }

  Future<void> deleteClass({required String projectId, required String classId}) async {
    try {
      final callable = _functions.httpsCallable('deleteIndependentTimetableClass', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({'projectId': projectId, 'classId': classId});
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not delete this class.');
    }
  }

  Future<({int assignmentCount, int conflictCount})> generate(String projectId) async {
    try {
      final callable = _functions.httpsCallable('generateIndependentTimetable', options: HttpsCallableOptions(timeout: const Duration(seconds: 60)));
      final result = await callable.call<Map<String, dynamic>>({'projectId': projectId});
      return (assignmentCount: (result.data['assignmentCount'] as num).toInt(), conflictCount: (result.data['conflictCount'] as num).toInt());
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not generate the timetable.');
    }
  }

  Stream<GeneratedTimetable?> watchGenerated(String projectId) => _projects
      .doc(projectId)
      .collection('timetable')
      .doc('generated')
      .snapshots()
      .map((doc) => doc.exists ? GeneratedTimetable.fromMap(doc.data()!) : null);

  /// Asks Gemini to explain the conflicts [generate] already found — see
  /// `explainIndependentTimetableConflicts` in index.ts. [watchGenerated]
  /// picks the result up automatically once it lands.
  Future<void> explainConflicts(String projectId) async {
    try {
      final callable = _functions.httpsCallable('explainIndependentTimetableConflicts', options: HttpsCallableOptions(timeout: const Duration(seconds: 60)));
      await callable.call<Map<String, dynamic>>({'projectId': projectId});
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not generate explanations right now.');
    }
  }

  /// Interprets typed text via `parseIndependentTimetableConstraint`.
  /// Read-only — matches against this project's own typed teacher names
  /// and classes, never applies anything itself; [ParsedTimetableConstraint.teacherUid]
  /// on the result is that matched teacher's own NAME (see
  /// [IndependentTimetableClass]'s doc comment), not a real account id.
  Future<ParsedTimetableConstraint> parseConstraint({required String projectId, required String text}) async {
    try {
      final callable = _functions.httpsCallable('parseIndependentTimetableConstraint', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({'projectId': projectId, 'text': text});
      return ParsedTimetableConstraint.fromMap(result.data.cast<String, dynamic>());
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not interpret that instruction.');
    }
  }

  /// Applies a CONFIRMED availability constraint. [teacherUid] is really
  /// the teacher's typed name, used as-is — see the module doc comment.
  Future<void> setTeacherAvailability({required String projectId, required String teacherUid, required List<String> unavailableSlots}) async {
    try {
      final callable = _functions.httpsCallable('setIndependentTeacherAvailability', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({'projectId': projectId, 'teacherUid': teacherUid, 'unavailableSlots': unavailableSlots});
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not save that availability constraint.');
    }
  }

  /// Applies a CONFIRMED assignment constraint from
  /// [parseConstraint]/[extractFromPhotos] — reads the current class,
  /// merges in the one subject->teacher pairing, and saves the whole
  /// class back through the existing `saveIndependentTimetableClass`
  /// (there's no separate "assign one subject" function here, unlike
  /// School Network's real `assignSubjectTeacher`, since an independent
  /// class doc is small enough that a full save is simplest).
  Future<void> assignSubjectTeacher({required String projectId, required String classId, required String subjectName, required String teacherName}) async {
    final snap = await _projects.doc(projectId).collection('classes').doc(classId).get();
    if (!snap.exists) throw const SchoolException('That class no longer exists — it may have been deleted.');
    final current = IndependentTimetableClass.fromMap(snap.id, snap.data()!);
    final subjectNames = current.subjectNames.contains(subjectName) ? current.subjectNames : [...current.subjectNames, subjectName];
    final subjectTeacherNames = {...current.subjectTeacherNames, subjectName: teacherName};
    await saveClass(projectId: projectId, classId: classId, classGrade: current.classGrade, subjectNames: subjectNames, subjectTeacherNames: subjectTeacherNames);
  }

  /// Reads a photographed paper timetable via
  /// `extractIndependentTimetableFromPhoto`. Read-only: nothing is
  /// applied until the operator reviews and confirms in the UI.
  Future<ExtractedTimetable> extractFromPhotos({required String projectId, required List<File> pageFiles}) async {
    try {
      final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
      final callable = _functions.httpsCallable('extractIndependentTimetableFromPhoto', options: HttpsCallableOptions(timeout: const Duration(seconds: 115)));
      final result = await callable.call<Map<String, dynamic>>({'projectId': projectId, 'pageImagesBase64': images});
      return ExtractedTimetable.fromMap(result.data.cast<String, dynamic>());
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not read this timetable.');
    }
  }

  /// Moves one lesson to a different day/period — the server re-checks
  /// the exact same conflict rules the engine enforces before writing
  /// anything. A successful move auto-locks the lesson.
  Future<void> moveAssignment({
    required String projectId,
    required String classId,
    required String subjectName,
    required String teacherUid,
    required int day,
    required int period,
    required int newDay,
    required int newPeriod,
  }) async {
    try {
      final callable = _functions.httpsCallable('moveIndependentTimetableAssignment', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'projectId': projectId,
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

  /// Pins/unpins one lesson so a regenerate does (or doesn't) leave it
  /// exactly where it is.
  Future<void> setAssignmentLocked({
    required String projectId,
    required String classId,
    required String subjectName,
    required String teacherUid,
    required int day,
    required int period,
    required bool locked,
  }) async {
    try {
      final callable = _functions.httpsCallable('setIndependentTimetableAssignmentLocked', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'projectId': projectId,
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
}
