import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../models/home_assignment.dart';

class HomeAssignmentException implements Exception {
  final String message;
  const HomeAssignmentException(this.message);
  @override
  String toString() => message;
}

/// Home Assignment epic, Stages 7-12 — client side of every
/// `*HomeAssignment*`/`*PupilClassLink*` Cloud Function, plus the
/// read-only Firestore streams every screen in this epic watches.
class HomeAssignmentService {
  HomeAssignmentService({FirebaseFunctions? functions, FirebaseFirestore? firestore, FirebaseStorage? storage})
      : _functions = functions ?? FirebaseFunctions.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;

  CollectionReference<Map<String, dynamic>> _assignmentsRef(String schoolId, String classId) =>
      _firestore.collection('schools').doc(schoolId).collection('classes').doc(classId).collection('homeAssignments');

  Stream<List<IssuedHomeAssignment>> watchAssignments(String schoolId, String classId) {
    return _assignmentsRef(schoolId, classId).orderBy('createdAt', descending: true).snapshots().map(
          (snap) => snap.docs.map((d) => IssuedHomeAssignment.fromMap(d.id, d.data())).toList(),
        );
  }

  Future<IssuedHomeAssignment?> getAssignment(String schoolId, String classId, String assignmentId) async {
    final doc = await _assignmentsRef(schoolId, classId).doc(assignmentId).get();
    return doc.exists ? IssuedHomeAssignment.fromMap(doc.id, doc.data()!) : null;
  }

  Stream<List<HomeAssignmentSubmission>> watchSubmissions(String schoolId, String classId, String assignmentId) {
    return _assignmentsRef(schoolId, classId).doc(assignmentId).collection('submissions').orderBy('submittedAt', descending: true).snapshots().map(
          (snap) => snap.docs.map((d) => HomeAssignmentSubmission.fromMap(d.id, d.data())).toList(),
        );
  }

  Future<
      ({
        String assignmentId,
        String referenceCode,
        int emailsSent,
        int emailsFailed,
        List<({String name, String phone})> whatsappRecipients
      })> sendToClass({
    required String schoolId,
    required String classId,
    required String subjectName,
    required String title,
    required String instructions,
    required List<HomeAssignmentQuestion> questions,
    required String markingKeyTitle,
    required List<HomeAssignmentKeyEntry> markingKey,
    DateTime? deadline,
    Uint8List? attachmentPdfBytes,
    String? attachmentFilename,
  }) async {
    try {
      final callable = _functions.httpsCallable('sendHomeAssignmentToClass', options: HttpsCallableOptions(timeout: const Duration(seconds: 175)));
      final result = await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'classId': classId,
        'subjectName': subjectName,
        'title': title,
        'instructions': instructions,
        'questions': [for (final q in questions) {'number': q.number, 'text': q.text, 'maxMarks': q.maxMarks}],
        'markingKeyTitle': markingKeyTitle,
        'markingKey': [for (final k in markingKey) {'number': k.number, 'expectedAnswerOrKeywords': k.expectedAnswerOrKeywords}],
        if (deadline != null) 'deadlineIso': deadline.toIso8601String(),
        if (attachmentPdfBytes != null && attachmentFilename != null)
          'attachment': {'filename': attachmentFilename, 'base64': base64Encode(attachmentPdfBytes)},
      });
      final data = result.data;
      return (
        assignmentId: data['assignmentId'] as String,
        referenceCode: data['referenceCode'] as String,
        emailsSent: (data['emailsSent'] as num).toInt(),
        emailsFailed: (data['emailsFailed'] as num).toInt(),
        whatsappRecipients: ((data['whatsappRecipients'] as List?) ?? const [])
            .map((r) => (name: (r as Map)['name'] as String, phone: r['phone'] as String))
            .toList(),
      );
    } on FirebaseFunctionsException catch (e) {
      throw HomeAssignmentException(e.message ?? 'Could not send this home assignment.');
    }
  }

  /// Uploads [bytes] to this submission's own Storage folder and returns
  /// the storage path — call once per photo, then [recordSubmission] once
  /// with every resulting path.
  Future<String> uploadSubmissionPhoto({
    required String schoolId,
    required String classId,
    required String assignmentId,
    required String uploaderUid,
    required int index,
    required Uint8List bytes,
  }) async {
    final path = 'schools/$schoolId/classes/$classId/homeAssignments/$assignmentId/submissions/$uploaderUid/page_$index.jpg';
    try {
      await _storage.ref(path).putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      return path;
    } on FirebaseException catch (e) {
      throw HomeAssignmentException(e.message ?? 'Could not upload a photo.');
    }
  }

  Future<String> recordSubmission({
    required String schoolId,
    required String classId,
    required String assignmentId,
    required List<String> photoPaths,
    String? learnerName,
  }) async {
    try {
      final callable = _functions.httpsCallable('recordHomeAssignmentSubmission', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      final result = await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'classId': classId,
        'assignmentId': assignmentId,
        'photoPaths': photoPaths,
        if (learnerName != null) 'learnerName': learnerName,
      });
      return result.data['submissionId'] as String;
    } on FirebaseFunctionsException catch (e) {
      throw HomeAssignmentException(e.message ?? 'Could not submit these photos.');
    }
  }

  Future<Uint8List> downloadSubmissionPhoto(String path) async {
    try {
      final bytes = await _storage.ref(path).getData(15 * 1024 * 1024);
      if (bytes == null) throw const HomeAssignmentException('That photo could not be downloaded.');
      return bytes;
    } on FirebaseException catch (e) {
      throw HomeAssignmentException(e.message ?? 'Could not download a submitted photo.');
    }
  }

  Future<void> recordMarkingResult({
    required String schoolId,
    required String classId,
    required String assignmentId,
    required String submissionId,
    required double score,
    required double maxScore,
    required List<Map<String, dynamic>> answers,
    required String markingEngine,
  }) async {
    try {
      final callable = _functions.httpsCallable('recordHomeAssignmentMarkingResult', options: HttpsCallableOptions(timeout: const Duration(seconds: 30)));
      await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'classId': classId,
        'assignmentId': assignmentId,
        'submissionId': submissionId,
        'score': score,
        'maxScore': maxScore,
        'answers': answers,
        'markingEngine': markingEngine,
      });
    } on FirebaseFunctionsException catch (e) {
      throw HomeAssignmentException(e.message ?? 'Could not record this marking result.');
    }
  }

  Future<({int sent, int skipped, int emailsSent, int emailsFailed, List<({String name, String phone})> whatsappRecipients})> sendBatchResults({
    required String schoolId,
    required String classId,
    required String assignmentId,
    required List<String> submissionIds,
  }) async {
    try {
      final callable = _functions.httpsCallable('sendHomeAssignmentBatchResults', options: HttpsCallableOptions(timeout: const Duration(seconds: 175)));
      final result = await callable.call<Map<String, dynamic>>({
        'schoolId': schoolId,
        'classId': classId,
        'assignmentId': assignmentId,
        'submissionIds': submissionIds,
      });
      final data = result.data;
      return (
        sent: (data['sent'] as num).toInt(),
        skipped: (data['skipped'] as num).toInt(),
        emailsSent: (data['emailsSent'] as num).toInt(),
        emailsFailed: (data['emailsFailed'] as num).toInt(),
        whatsappRecipients: ((data['whatsappRecipients'] as List?) ?? const [])
            .map((r) => (name: (r as Map)['name'] as String, phone: r['phone'] as String))
            .toList(),
      );
    } on FirebaseFunctionsException catch (e) {
      throw HomeAssignmentException(e.message ?? 'Could not send this batch of results.');
    }
  }

  Future<({int remindedCount, int emailsSent, int emailsFailed, List<({String name, String phone})> whatsappRecipients})> remindNonSubmitters({
    required String schoolId,
    required String classId,
    required String assignmentId,
  }) async {
    try {
      final callable = _functions.httpsCallable('remindHomeAssignmentNonSubmitters', options: HttpsCallableOptions(timeout: const Duration(seconds: 175)));
      final result = await callable.call<Map<String, dynamic>>({'schoolId': schoolId, 'classId': classId, 'assignmentId': assignmentId});
      final data = result.data;
      return (
        remindedCount: (data['remindedCount'] as num).toInt(),
        emailsSent: (data['emailsSent'] as num).toInt(),
        emailsFailed: (data['emailsFailed'] as num).toInt(),
        whatsappRecipients: ((data['whatsappRecipients'] as List?) ?? const [])
            .map((r) => (name: (r as Map)['name'] as String, phone: r['phone'] as String))
            .toList(),
      );
    } on FirebaseFunctionsException catch (e) {
      throw HomeAssignmentException(e.message ?? 'Could not send reminders.');
    }
  }
}
