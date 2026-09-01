import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

class CoverPageFields {
  final String studentName;
  final String idNumber;
  final String course;
  final String subject;
  final String assignmentTitle;
  final String teacherName;
  final String date;
  final String institution;
  final String notes;

  const CoverPageFields({
    this.studentName = '',
    this.idNumber = '',
    this.course = '',
    this.subject = '',
    this.assignmentTitle = '',
    this.teacherName = '',
    this.date = '',
    this.institution = '',
    this.notes = '',
  });

  factory CoverPageFields.fromMap(Map<Object?, Object?> map) => CoverPageFields(
        studentName: map['studentName'] as String? ?? '',
        idNumber: map['idNumber'] as String? ?? '',
        course: map['course'] as String? ?? '',
        subject: map['subject'] as String? ?? '',
        assignmentTitle: map['assignmentTitle'] as String? ?? '',
        teacherName: map['teacherName'] as String? ?? '',
        date: map['date'] as String? ?? '',
        institution: map['institution'] as String? ?? '',
        notes: map['notes'] as String? ?? '',
      );
}

class CoverPageExtractionUnavailable implements Exception {
  final String message;
  const CoverPageExtractionUnavailable(this.message);
  @override
  String toString() => message;
}

/// Assignment Submission, Stage 1's OCR step — calls the
/// `extractCoverPageFields` Cloud Function. Pure convenience: the caller
/// always shows the result in an editable form, never treats it as final.
class CoverPageExtractionService {
  CoverPageExtractionService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<CoverPageFields> extract(File coverPhoto) async {
    if (!await isOnline) {
      throw const CoverPageExtractionUnavailable("You're offline. Connect to the internet to read the cover page.");
    }
    await AuthService.instance.ensureSignedIn();

    final bytes = await coverPhoto.readAsBytes();
    final callable = _functions.httpsCallable('extractCoverPageFields');
    try {
      final result = await callable.call<Map<Object?, Object?>>({'imageBase64': base64Encode(bytes)});
      return CoverPageFields.fromMap(result.data);
    } on FirebaseFunctionsException catch (e) {
      throw CoverPageExtractionUnavailable(e.message ?? 'Failed to read the cover page.');
    }
  }
}
