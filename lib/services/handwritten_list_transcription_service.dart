import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request", and for a response that doesn't match the
/// expected shape.
class HandwrittenListTranscriptionUnavailable implements Exception {
  final String message;
  const HandwrittenListTranscriptionUnavailable(this.message);
  @override
  String toString() => message;
}

/// A generically-transcribed table — whatever columns and rows were
/// actually on the photographed list, not forced into a fixed shape.
/// [headers] is empty if the list had none.
class TranscribedTable {
  final List<String> headers;
  final List<List<String>> rows;
  final String notes;

  const TranscribedTable({required this.headers, required this.rows, required this.notes});
}

/// "Capture Manual Scores" — for teachers who mark scripts entirely by
/// hand and keep a running handwritten list, in whatever pattern they
/// use (a ruled table, a plain name/score list, anything else). Calls
/// `transcribeHandwrittenList` with photographed pages to get that list
/// back as a generic table, which HandwrittenListDocumentService then
/// turns into an actual editable .docx reproducing it — reviewed and
/// corrected by the teacher in Word itself, not inside this app.
class HandwrittenListTranscriptionService {
  HandwrittenListTranscriptionService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<TranscribedTable> transcribe(List<File> pageFiles) async {
    if (!await isOnline) {
      throw const HandwrittenListTranscriptionUnavailable("You're offline. Connect to the internet to transcribe this list.");
    }

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable(
      'transcribeHandwrittenList',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 110)),
    );

    Object? rawData;
    try {
      final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
      final result = await callable.call<Object?>({'pageImagesBase64': images});
      rawData = result.data;
    } on FirebaseFunctionsException catch (e) {
      throw HandwrittenListTranscriptionUnavailable(e.message ?? 'Failed to transcribe this list.');
    }

    // Fully defensive — `is` checks rather than blind casts, at every
    // level, so a response that doesn't match the expected shape (a
    // genuine AI slip, or any future change server-side) produces a
    // clear, actionable message instead of a raw Dart TypeError leaking
    // to the UI. This is exactly the bug class that broke this feature
    // before: a narrow `on FirebaseFunctionsException` catch didn't
    // catch the TypeError from an unguarded cast, so it surfaced as a
    // raw error screen instead of a message.
    if (rawData is! Map) {
      throw const HandwrittenListTranscriptionUnavailable('The transcription response was in an unexpected format.');
    }
    final data = rawData;

    final headersRaw = data['headers'];
    final headers = headersRaw is List ? headersRaw.whereType<String>().toList() : <String>[];

    final rowsRaw = data['rows'];
    if (rowsRaw is! List) {
      throw const HandwrittenListTranscriptionUnavailable('The transcription response was in an unexpected format.');
    }
    final rows = <List<String>>[
      for (final r in rowsRaw)
        if (r is List) r.whereType<String>().toList(),
    ];
    if (rows.isEmpty) {
      throw const HandwrittenListTranscriptionUnavailable('No rows could be found on that list.');
    }

    final notes = data['notes'];
    return TranscribedTable(headers: headers, rows: rows, notes: notes is String ? notes : '');
  }
}
