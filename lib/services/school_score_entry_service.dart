import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/school.dart';
import 'school_service.dart' show SchoolException;

/// School Network, Milestone B2 (added 2026-09-13) — Stage 4's actual
/// score-writing action, plus Stage 6's in-app edit notifications. Every
/// write goes through `submitClassScoreEntry` (see its own comment in
/// index.ts for the real permission/audit-trail logic); this class only
/// reads and calls that one function.
class SchoolScoreEntryService {
  SchoolScoreEntryService({FirebaseFunctions? functions, FirebaseFirestore? firestore})
      : _functions = functions ?? FirebaseFunctions.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;

  Future<void> submitScore({
    required String schoolId,
    required String classId,
    required int learnerIndex,
    required String subjectName,
    required double score,
    String comment = '',
  }) async {
    try {
      final callable = _functions.httpsCallable('submitClassScoreEntry', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'classId': classId,
        'learnerIndex': learnerIndex,
        'subjectName': subjectName,
        'score': score,
        'comment': comment,
      });
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not save that score.');
    }
  }

  Stream<List<ScoreEntry>> watchEntries(String schoolId, String classId) {
    return _firestore
        .collection('schools')
        .doc(schoolId)
        .collection('classes')
        .doc(classId)
        .collection('scoreEntries')
        .snapshots()
        .map((snap) => snap.docs.map((d) => ScoreEntry.fromMap(d.id, d.data())).toList());
  }

  /// Every class, across the whole school, where [myUid] is assigned to
  /// teach at least one subject — the list a "Subject Teacher" entry
  /// screen shows. Scoped to one known school (never a cross-school
  /// `collectionGroup` query — a teacher belongs to exactly one school at
  /// a time), so the existing per-school `classes` read rule already
  /// covers this.
  Future<List<SchoolClass>> myAssignedClasses(String schoolId, String myUid) async {
    final snap = await _firestore
        .collection('schools')
        .doc(schoolId)
        .collection('classes')
        .where('assignedTeacherUids', arrayContains: myUid)
        .get();
    return snap.docs.map((d) => SchoolClass.fromMap(d.id, d.data())).toList();
  }
}
