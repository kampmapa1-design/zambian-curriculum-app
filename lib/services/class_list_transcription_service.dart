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

    Object? rawData;
    try {
      final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
      final result = await callable.call<Object?>({'pageImagesBase64': images});
      rawData = result.data;
    } on FirebaseFunctionsException catch (e) {
      throw ClassListTranscriptionUnavailable(e.message ?? 'Failed to transcribe this class list.');
    }

    // Defensive from here on — validated with `is` checks rather than
    // blind casts, so a response that doesn't match the expected shape
    // (a genuine AI slip, or any future change to what the Cloud
    // Function returns) produces a clear, actionable message instead of
    // a raw Dart TypeError leaking to the UI. Rows that don't match are
    // skipped individually rather than failing the whole transcription.
    if (rawData is! Map) {
      throw const ClassListTranscriptionUnavailable('The transcription response was in an unexpected format.');
    }
    final data = rawData;
    final entriesRaw = data['entries'];
    if (entriesRaw is! List) {
      throw const ClassListTranscriptionUnavailable('The transcription response was in an unexpected format.');
    }

    final entries = <TranscribedClassListEntry>[];
    for (final e in entriesRaw) {
      if (e is! Map) continue;
      final firstName = e['firstName'];
      final surname = e['surname'];
      final score = e['score'];
      entries.add(TranscribedClassListEntry(
        firstName: firstName is String ? firstName : '',
        surname: surname is String ? surname : '',
        score: score is num ? score.toDouble() : 0,
      ));
    }
    if (entries.isEmpty) {
      throw const ClassListTranscriptionUnavailable('No rows could be found on that class list.');
    }

    final notes = data['notes'];
    return TranscribedClassList(entries: entries, notes: notes is String ? notes : '');
  }
}
