import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

class TeachingNotesResult {
  final String notes;
  final String topic;
  final String? subtopic;
  final String format;

  const TeachingNotesResult({
    required this.notes,
    required this.topic,
    this.subtopic,
    required this.format,
  });

  factory TeachingNotesResult.fromMap(Map<Object?, Object?> map) => TeachingNotesResult(
        notes: map['notes'] as String,
        topic: map['topic'] as String,
        subtopic: map['subtopic'] as String?,
        format: map['format'] as String,
      );
}

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request" — either way there's a user-facing message to show.
class TeachingNotesUnavailable implements Exception {
  final String message;
  const TeachingNotesUnavailable(this.message);
  @override
  String toString() => message;
}

/// Calls the `generateTeachingNotes` Cloud Function (Gemini-backed — this
/// app moved off Anthropic entirely 2026-08-26, see index.ts's own doc
/// comment). Unlike most of this app, this needs a live connection, so
/// every call checks connectivity first and fails fast with a clear
/// message instead of hanging.
class TeachingNotesService {
  TeachingNotesService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// [subject] (and, when known, [grade]) is required — real, reported bug
  /// fixed 2026-09-03: without an explicit subject, a generic topic name
  /// gave the model nothing to disambiguate against its own general
  /// knowledge, and it could write about a different subject's version of
  /// a similarly-named topic entirely. See `buildPrompt` in index.ts for
  /// the actual grounding instruction this enables.
  Future<TeachingNotesResult> generate({
    required String topic,
    String? subtopic,
    required String subject,
    String? grade,
    required String syllabusContext,
    required String format,
    bool onePage = false,
  }) async {
    if (!await isOnline) {
      throw const TeachingNotesUnavailable(
        "You're offline. Connect to the internet to generate teaching notes.",
      );
    }

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable('generateTeachingNotes');
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'topic': topic,
        if (subtopic != null) 'subtopic': subtopic,
        'subject': subject,
        if (grade != null) 'grade': grade,
        'syllabusContext': syllabusContext,
        'format': format,
        if (onePage) 'maxLength': 'page',
      });
      return TeachingNotesResult.fromMap(result.data);
    } on FirebaseFunctionsException catch (e) {
      throw TeachingNotesUnavailable(e.message ?? 'Failed to generate teaching notes.');
    }
  }
}
