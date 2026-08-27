import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

/// Thrown when text can't be extracted right now (offline, or the
/// function rejected the request) — callers should keep the original file
/// and try extraction again later rather than losing the material.
class SubjectContentExtractionUnavailable implements Exception {
  final String message;
  const SubjectContentExtractionUnavailable(this.message);
  @override
  String toString() => message;
}

/// Calls the `extractSubjectContentTextFn` Cloud Function to turn a
/// downloaded PDF's raw bytes into the plain teaching-content text stored
/// in the Subject Content Database (see SubjectContentRepository) — needs
/// a live connection, same as any other Cloud Function call in this app.
class SubjectContentExtractionService {
  SubjectContentExtractionService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<String> extractText(List<int> pdfBytes) async {
    if (!await isOnline) {
      throw const SubjectContentExtractionUnavailable("You're offline. Connect to the internet to process this file.");
    }

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable(
      'extractSubjectContentTextFn',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 90)),
    );
    try {
      final result = await callable.call<Map<Object?, Object?>>({'base64': base64Encode(pdfBytes)});
      final text = result.data['text'] as String?;
      if (text == null) {
        throw const SubjectContentExtractionUnavailable('No text could be extracted from this file.');
      }
      return text;
    } on FirebaseFunctionsException catch (e) {
      throw SubjectContentExtractionUnavailable(e.message ?? 'Failed to process this file.');
    }
  }
}
