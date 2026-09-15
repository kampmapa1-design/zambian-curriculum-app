import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/report_class.dart';
import '../models/school.dart';
import 'report_class_repository.dart';
import 'school_service.dart' show SchoolException;

/// School Network, Milestone B1 (added 2026-09-13) — links a local, purely
/// on-device [ReportClass] to a shared [SchoolClass] in Firestore, and
/// manages per-subject teacher assignment on it. See `connectClassToSchool`/
/// `assignSubjectTeacher` in firebase/functions/src/index.ts for the real
/// permission logic — this class is a thin, honest wrapper around those two
/// Cloud Functions plus the read-only [SchoolClass] stream.
class SchoolClassLinkService {
  SchoolClassLinkService({FirebaseFunctions? functions, FirebaseFirestore? firestore, ReportClassRepository? reportClassRepository})
      : _functions = functions ?? FirebaseFunctions.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _reportClassRepository = reportClassRepository ?? ReportClassRepository();

  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;
  final ReportClassRepository _reportClassRepository;

  /// Connects [reportClass] to the school's shared class registry —
  /// publishing a snapshot of its current roster/subject list — and
  /// records the resulting `firestoreClassId` back onto the local class
  /// row. Safe to call again later (e.g. the roster changed): it refreshes
  /// the same connected class rather than creating a duplicate.
  ///
  /// [guardianContacts], when provided, is Stage 9's broadcast feature
  /// (added 2026-09-13, per explicit user confirmation of the real
  /// privacy decision this represents — guardian phone/email was
  /// previously local-only data, never synced anywhere) — parallel to
  /// [learnerNames], published to a SEPARATE leadership-only-readable doc
  /// server-side (see connectClassToSchool in index.ts), never merged
  /// onto the class doc every member can read. Omit entirely to connect
  /// the class without publishing any guardian data at all.
  Future<SchoolClass> connectClass({
    required String schoolId,
    required ReportClass reportClass,
    required List<String> learnerNames,
    required List<String> subjectNames,
    List<({String? email, String? phone})>? guardianContacts,
  }) async {
    try {
      final callable = _functions.httpsCallable('connectClassToSchool', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'classGrade': reportClass.classGrade,
        'term': reportClass.term,
        'learnerNames': learnerNames,
        'subjectNames': subjectNames,
        if (guardianContacts != null)
          'guardianContacts': [for (final c in guardianContacts) {'email': c.email, 'phone': c.phone}],
      });
      final classId = result.data['classId'] as String;
      await _reportClassRepository.setFirestoreClassId(reportClass.id, classId);
      final schoolClass = await getClass(schoolId, classId);
      if (schoolClass == null) {
        throw const SchoolException('Class was connected but could not be loaded. Try again.');
      }
      return schoolClass;
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not connect this class to the school.');
    }
  }

  Future<void> assignSubjectTeacher({
    required String schoolId,
    required String classId,
    required String subjectName,
    required String? targetUid,
  }) async {
    try {
      final callable = _functions.httpsCallable('assignSubjectTeacher', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'classId': classId,
        'subjectName': subjectName,
        'targetUid': targetUid,
      });
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not assign that subject teacher.');
    }
  }

  Future<SchoolClass?> getClass(String schoolId, String classId) async {
    final doc = await _firestore.collection('schools').doc(schoolId).collection('classes').doc(classId).get();
    if (!doc.exists) return null;
    return SchoolClass.fromMap(doc.id, doc.data()!);
  }

  Stream<SchoolClass?> watchClass(String schoolId, String classId) {
    return _firestore
        .collection('schools')
        .doc(schoolId)
        .collection('classes')
        .doc(classId)
        .snapshots()
        .map((doc) => doc.exists ? SchoolClass.fromMap(doc.id, doc.data()!) : null);
  }
}
