import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/assignment_submission.dart';
import 'auth_service.dart';

class TranscribedReferencePage {
  final List<String> entries;
  final String notes;

  const TranscribedReferencePage({required this.entries, required this.notes});

  factory TranscribedReferencePage.fromMap(Map<Object?, Object?> map) => TranscribedReferencePage(
        entries: ((map['entries'] as List?) ?? const []).cast<String>(),
        notes: map['notes'] as String? ?? '',
      );
}

class ReferencePageTranscriptionUnavailable implements Exception {
  final String message;
  const ReferencePageTranscriptionUnavailable(this.message);
  @override
  String toString() => message;
}

/// Assignment Submission, Stage 4 — calls the `transcribeReferencePage`
/// Cloud Function, passing along the reference system chosen in Stage 3
/// so formatting is preserved accurately rather than guessed generically.
class ReferencePageTranscriptionService {
  ReferencePageTranscriptionService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<TranscribedReferencePage> transcribe({
    required List<File> pageFiles,
    required ReferenceSystem referenceSystem,
  }) async {
    if (!await isOnline) {
      throw const ReferencePageTranscriptionUnavailable(
        "You're offline. Connect to the internet to transcribe the reference page.",
      );
    }
    await AuthService.instance.ensureSignedIn();

    final images = <String>[];
    for (final file in pageFiles) {
      images.add(base64Encode(await file.readAsBytes()));
    }

    final callable = _functions.httpsCallable('transcribeReferencePage');
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'pageImagesBase64': images,
        'referenceSystem': referenceSystem.label,
      });
      return TranscribedReferencePage.fromMap(result.data);
    } on FirebaseFunctionsException catch (e) {
      throw ReferencePageTranscriptionUnavailable(e.message ?? 'Failed to transcribe the reference page.');
    }
  }
}
