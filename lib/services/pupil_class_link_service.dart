import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

class PupilClassLinkException implements Exception {
  final String message;
  const PupilClassLinkException(this.message);
  @override
  String toString() => message;
}

/// A pupil's own pending or resolved request to link their account to one
/// class roster slot — Home Assignment epic, Stage 1/7/8.
class PupilClassLinkRequest {
  final String pupilUid;
  final String learnerName;
  final DateTime? requestedAt;
  const PupilClassLinkRequest({required this.pupilUid, required this.learnerName, required this.requestedAt});

  factory PupilClassLinkRequest.fromMap(String pupilUid, Map<String, dynamic> data) => PupilClassLinkRequest(
        pupilUid: pupilUid,
        learnerName: data['learnerName'] as String? ?? '',
        requestedAt: (data['requestedAt'] as Timestamp?)?.toDate(),
      );
}

/// Client side of `requestPupilClassLink`/`respondToPupilClassLink`. Real
/// gating happens server-side (see those functions' own comments) —
/// deliberately kept separate from [SchoolService], since a pupil's
/// custom claims (`pupilSchoolId`/`pupilClassId`) are a different concept
/// from a staff member's `schoolId`/`schoolRole`.
class PupilClassLinkService {
  PupilClassLinkService({FirebaseFunctions? functions, FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _functions = functions ?? FirebaseFunctions.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// The current user's `pupilSchoolId`/`pupilClassId`, from their ID
  /// token's custom claims — mirrors SchoolService.currentSchoolClaim.
  Future<({String? schoolId, String? classId})> currentPupilClaim({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) return (schoolId: null, classId: null);
    final result = await user.getIdTokenResult(forceRefresh);
    return (schoolId: result.claims?['pupilSchoolId'] as String?, classId: result.claims?['pupilClassId'] as String?);
  }

  Future<({String schoolId, String schoolName, List<({String id, String classGrade, String term})> classes})> listClassesByCode(String schoolCode) async {
    try {
      final callable = _functions.httpsCallable('listSchoolClassesByCode', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({'schoolCode': schoolCode});
      final data = result.data;
      return (
        schoolId: data['schoolId'] as String,
        schoolName: data['schoolName'] as String,
        classes: ((data['classes'] as List?) ?? const [])
            .map((c) => (id: (c as Map)['id'] as String, classGrade: c['classGrade'] as String, term: c['term'] as String))
            .toList(),
      );
    } on FirebaseFunctionsException catch (e) {
      throw PupilClassLinkException(e.message ?? 'Could not find that school.');
    }
  }

  Future<({String schoolId, String schoolName, String className})> requestLink({
    required String schoolCode,
    required String classId,
    required String learnerName,
  }) async {
    try {
      final callable = _functions.httpsCallable('requestPupilClassLink', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({'schoolCode': schoolCode, 'classId': classId, 'learnerName': learnerName});
      final data = result.data;
      return (schoolId: data['schoolId'] as String, schoolName: data['schoolName'] as String, className: data['className'] as String);
    } on FirebaseFunctionsException catch (e) {
      throw PupilClassLinkException(e.message ?? 'Could not request to join this class.');
    }
  }

  Stream<List<PupilClassLinkRequest>> watchPendingLinks(String schoolId, String classId) {
    return _firestore
        .collection('schools')
        .doc(schoolId)
        .collection('classes')
        .doc(classId)
        .collection('pupilClassLinks')
        .snapshots()
        .map((snap) => snap.docs.map((d) => PupilClassLinkRequest.fromMap(d.id, d.data())).toList());
  }

  Future<void> respondToLink({required String schoolId, required String classId, required String pupilUid, required bool approve}) async {
    try {
      final callable = _functions.httpsCallable('respondToPupilClassLink', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({'schoolId': schoolId, 'classId': classId, 'pupilUid': pupilUid, 'approve': approve});
    } on FirebaseFunctionsException catch (e) {
      throw PupilClassLinkException(e.message ?? 'Could not update that join request.');
    }
  }
}
