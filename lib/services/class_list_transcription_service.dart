import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request".
class ClassListTranscriptionUnavailable implements Exception {
  final String message;
  const ClassListTranscriptionUnavailable(this.message);
  @override
  String toString() => message;
}

/// One transcribed row — always a draft a teacher reviews and can edit
/// (see ClassListImportScreen), same "never trust AI output directly"
/// pattern as everywhere else in this feature.
class TranscribedClassListEntry {
  final String firstName;
  final String surname;
  final double score;

  const TranscribedClassListEntry({required this.firstName, required this.surname, required this.score});
}

class TranscribedClassList {
  final List<TranscribedClassListEntry> entries;
  final String notes;

  const TranscribedClassList({required this.entries, required this.notes});
}

/// For teachers who mark scripts entirely by hand and keep a handwritten
/// class list (name + score) rather than using this app's AI grading
/// pipeline — calls `transcribeClassList` with photographed pages of that
/// list to get a typed draft, which ClassListImportScreen then turns into
/// real MarkingScript records once a teacher has reviewed every row.
class ClassListTranscriptionService {
  ClassListTranscriptionService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<TranscribedClassList> transcribe(List<File> pageFiles) async {
    if (!await isOnline) {
      throw const ClassListTranscriptionUnavailable("You're offline. Connect to the internet to transcribe this list.");
    }

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable(
      'transcribeClassList',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 110)),
    );
    try {
      final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
      final result = await callable.call<Map<Object?, Object?>>({'pageImagesBase64': images});
      final entriesRaw = (result.data['entries'] as List?) ?? const [];
      final entries = [
        for (final e in entriesRaw.cast<Map<Object?, Object?>>())
          TranscribedClassListEntry(
            firstName: e['firstName'] as String? ?? '',
            surname: e['surname'] as String? ?? '',
            score: ((e['score'] as num?) ?? 0).toDouble(),
          ),
      ];
      if (entries.isEmpty) {
        throw const ClassListTranscriptionUnavailable('No rows could be found on that class list.');
      }
      return TranscribedClassList(entries: entries, notes: result.data['notes'] as String? ?? '');
    } on FirebaseFunctionsException catch (e) {
      throw ClassListTranscriptionUnavailable(e.message ?? 'Failed to transcribe this class list.');
    }
  }
}
