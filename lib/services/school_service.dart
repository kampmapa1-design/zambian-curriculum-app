import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/school.dart';
import 'auth_service.dart';

class SchoolException implements Exception {
  final String message;
  const SchoolException(this.message);
  @override
  String toString() => message;
}

/// School Network (Stages 1-3, added 2026-09-13) — client side of
/// `registerSchool`/`joinSchoolByCode`/`updateSchoolMemberRole`. Every
/// permission-sensitive write goes through one of those three Cloud
/// Functions (see their own doc comments in
/// firebase/functions/src/index.ts) — this class never writes to
/// `schools/**` directly, only reads it (gated by the caller's own
/// `schoolId` custom claim, checked server-side by Firestore rules).
class SchoolService {
  SchoolService({FirebaseFunctions? functions, FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _functions = functions ?? FirebaseFunctions.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// The current user's `schoolId`/`schoolRole`, read from their ID
  /// token's custom claims (set server-side by the three functions above).
  /// [forceRefresh] should be true right after calling one of those three,
  /// so the freshly-stamped claims actually reach the client.
  Future<({String? schoolId, SchoolRole? role})> currentSchoolClaim({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) return (schoolId: null, role: null);
    final result = await user.getIdTokenResult(forceRefresh);
    final schoolId = result.claims?['schoolId'] as String?;
    final roleWire = result.claims?['schoolRole'] as String?;
    return (schoolId: schoolId, role: schoolId == null ? null : SchoolRole.fromWire(roleWire));
  }

  Future<School?> getCurrentSchool({bool forceRefreshClaims = false}) async {
    final claim = await currentSchoolClaim(forceRefresh: forceRefreshClaims);
    if (claim.schoolId == null) return null;
    return getSchool(claim.schoolId!);
  }

  Future<School?> getSchool(String schoolId) async {
    final doc = await _firestore.collection('schools').doc(schoolId).get();
    if (!doc.exists) return null;
    return School.fromMap(doc.id, doc.data()!);
  }

  Stream<List<SchoolMember>> watchMembers(String schoolId) {
    return _firestore
        .collection('schools')
        .doc(schoolId)
        .collection('members')
        .snapshots()
        .map((snap) => snap.docs.map((d) => SchoolMember.fromMap(d.id, d.data())).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())));
  }

  Future<SchoolMember?> getMember(String schoolId, String uid) async {
    final doc = await _firestore.collection('schools').doc(schoolId).collection('members').doc(uid).get();
    if (!doc.exists) return null;
    return SchoolMember.fromMap(doc.id, doc.data()!);
  }

  Future<School> registerSchool({
    required String name,
    required String province,
    required String district,
    required String headTeacherName,
  }) async {
    await AuthService.instance.ensureSignedIn();
    try {
      final callable = _functions.httpsCallable('registerSchool', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({
        'name': name,
        'province': province,
        'district': district,
        'headTeacherName': headTeacherName,
      });
      final schoolId = result.data['schoolId'] as String;
      await currentSchoolClaim(forceRefresh: true);
      final school = await getSchool(schoolId);
      if (school == null) throw const SchoolException('School was created but could not be loaded. Try reopening My School.');
      return school;
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not register the school.');
    }
  }

  Future<School> joinSchool({required String code, required String name}) async {
    await AuthService.instance.ensureSignedIn();
    try {
      final callable = _functions.httpsCallable('joinSchoolByCode', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({'code': code, 'name': name});
      final schoolId = result.data['schoolId'] as String;
      await currentSchoolClaim(forceRefresh: true);
      final school = await getSchool(schoolId);
      if (school == null) throw const SchoolException('Joined the school but could not load its details. Try reopening My School.');
      return school;
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not join that school.');
    }
  }

  /// Assigns [role] to [targetUid] within [schoolId]. [classIds] only
  /// matters when [role] is [SchoolRole.gradeTeacher]. The real permission
  /// check (who's allowed to assign what) happens server-side — see
  /// `updateSchoolMemberRole` in index.ts; this call simply surfaces
  /// whatever it decides.
  Future<void> updateMemberRole({
    required String schoolId,
    required String targetUid,
    required SchoolRole role,
    List<String>? classIds,
  }) async {
    try {
      final callable = _functions.httpsCallable('updateSchoolMemberRole', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'targetUid': targetUid,
        'role': role.wireValue,
        if (classIds != null) 'classIds': classIds,
      });
      if (_auth.currentUser?.uid == targetUid) {
        await currentSchoolClaim(forceRefresh: true);
      }
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not update that role.');
    }
  }

  /// Timetable Generation, Stage 9 — appoints/revokes a co-opted
  /// "Timetable Operator". Real permission check (leadership/
  /// administrator only) happens server-side, see `setTimetableOperator`
  /// in index.ts.
  Future<void> setTimetableOperator({required String schoolId, required String targetUid, required bool isOperator}) async {
    try {
      final callable = _functions.httpsCallable('setTimetableOperator', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({'schoolId': schoolId, 'targetUid': targetUid, 'isOperator': isOperator});
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not update that Timetable Operator setting.');
    }
  }

  /// Stage 5's Mid-Term Results Window (minimal version) — real
  /// permission check (head_teacher/deputy only) happens server-side, see
  /// `setMidTermWindow` in index.ts.
  Future<void> setMidTermWindow({required String schoolId, required DateTime startDate}) async {
    try {
      final callable = _functions.httpsCallable('setMidTermWindow', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({'schoolId': schoolId, 'startDateIso': startDate.toIso8601String()});
    } on FirebaseFunctionsException catch (e) {
      throw SchoolException(e.message ?? 'Could not set the Mid-Term Results Window.');
    }
  }
}
