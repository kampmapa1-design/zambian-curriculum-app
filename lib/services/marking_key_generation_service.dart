import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/marking_scheme.dart';
import 'auth_service.dart';

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request".
class MarkingKeyGenerationUnavailable implements Exception {
  final String message;
  const MarkingKeyGenerationUnavailable(this.message);
  @override
  String toString() => message;
}

/// What kind of document the source is — changes both the Cloud
/// Function's prompt and the risk profile of the result. A question
/// paper doesn't contain its own answers (the AI has to answer each
/// question itself); an existing marking key already does (the AI is
/// just reading and structuring it, much lower risk of being wrong).
enum MarkingKeySourceType {
  questionPaper,
  markingKey;

  String get wireValue => switch (this) {
        MarkingKeySourceType.questionPaper => 'questionPaper',
        MarkingKeySourceType.markingKey => 'markingKey',
      };
}

/// [MarkingKeyGenerationService.derive]'s result — AI-suggested questions
/// plus any notes worth a teacher's attention before trusting them (an
/// assumed mark allocation, an uncertain answer, etc).
class DerivedMarkingKey {
  final List<MarkingSchemeQuestion> questions;
  final String notes;

  /// The document's own title/heading, exactly as the AI found it on the
  /// page (e.g. "Grade 12 Mathematics Final Examination") — empty string
  /// if none was genuinely visible. Used to gently flag a mismatch
  /// against what the teacher manually types for "type of exam" on the
  /// intake form, not to auto-fill or override it.
  final String detectedTitle;

  const DerivedMarkingKey({required this.questions, required this.notes, this.detectedTitle = ''});
}

/// AI-Assisted Marking, Stage B — calls `deriveMarkingKeyFromQuestionPaper`
/// with either already-extracted text (PDF path — see
/// SubjectContentExtractionService for the PDF-to-text step) or
/// photographed page images (camera-capture path) to get a draft marking
/// key. Always a draft: the result is meant to pre-fill
/// MarkingSchemeBuilderScreen for a teacher to review and edit, never
/// saved directly — see the Cloud Function's own comment for why.
class MarkingKeyGenerationService {
  MarkingKeyGenerationService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<DerivedMarkingKey> deriveFromText(
    String documentText, {
    required MarkingKeySourceType sourceType,
    void Function(String status)? onProgress,
  }) =>
      _derive({'questionPaperText': documentText, 'sourceType': sourceType.wireValue}, onProgress);

  Future<DerivedMarkingKey> deriveFromImages(
    List<File> pageFiles, {
    required MarkingKeySourceType sourceType,
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Preparing photos…');
    final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
    return _derive({'pageImagesBase64': images, 'sourceType': sourceType.wireValue}, onProgress);
  }

  /// Same as [deriveFromImages], but for bytes already in hand (e.g. from
  /// a file_picker result whose `.path` may not be populated on every
  /// platform) rather than re-reading from a [File].
  Future<DerivedMarkingKey> deriveFromImageBytes(
    List<List<int>> imagesBytes, {
    required MarkingKeySourceType sourceType,
    void Function(String status)? onProgress,
  }) {
    onProgress?.call('Preparing photo…');
    final images = [for (final bytes in imagesBytes) base64Encode(bytes)];
    return _derive({'pageImagesBase64': images, 'sourceType': sourceType.wireValue}, onProgress);
  }

  Future<DerivedMarkingKey> _derive(Map<String, dynamic> data, void Function(String status)? onProgress) async {
    var lastStatus = 'starting';
    void track(String status) {
      lastStatus = status;
      onProgress?.call(status);
    }

    // Hard backstop covering EVERYTHING, including the connectivity check
    // itself — see HandwrittenListTranscriptionService.transcribe for the
    // full reasoning: a connectivity-plugin call that stalls ahead of the
    // timeout wrapper defeats it entirely, so nothing runs outside this.
    try {
      return await _doDerive(data, track).timeout(
        const Duration(seconds: 130),
        onTimeout: () => throw MarkingKeyGenerationUnavailable(
          'This is taking too long and may be stuck (last step: "$lastStatus"). Check your connection and try again.',
        ),
      );
    } on MarkingKeyGenerationUnavailable {
      rethrow;
    } catch (error) {
      throw MarkingKeyGenerationUnavailable('Could not generate a marking key (last step: "$lastStatus"): $error');
    }
  }

  Future<DerivedMarkingKey> _doDerive(Map<String, dynamic> data, void Function(String status) onProgress) async {
    onProgress('Checking connection…');
    if (!await isOnline) {
      throw const MarkingKeyGenerationUnavailable("You're offline. Connect to the internet to generate a marking key.");
    }
    onProgress('Signing in…');
    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable(
      'deriveMarkingKeyFromQuestionPaper',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 110)),
    );

    Object? rawData;
    try {
      onProgress('Reading with AI…');
      final result = await callable.call<Object?>(data);
      rawData = result.data;
    } on FirebaseFunctionsException catch (e) {
      throw MarkingKeyGenerationUnavailable(e.message ?? 'Failed to generate a marking key.');
    }

    // Defensive from here on — `is` checks rather than blind casts, so a
    // response that doesn't match the expected shape produces a clear
    // message instead of a raw Dart TypeError leaking to the UI. See
    // HandwrittenListTranscriptionService.transcribe for the same pattern and
    // the bug it was added to fix.
    if (rawData is! Map) {
      throw const MarkingKeyGenerationUnavailable('The marking key response was in an unexpected format.');
    }
    final responseData = rawData;
    final questionsRaw = responseData['questions'];
    if (questionsRaw is! List) {
      throw const MarkingKeyGenerationUnavailable('The marking key response was in an unexpected format.');
    }

    final questions = <MarkingSchemeQuestion>[];
    for (final q in questionsRaw) {
      if (q is! Map) continue;
      final label = q['label'];
      final expected = q['expectedAnswerOrKeywords'];
      final maxMarks = q['maxMarks'];
      questions.add(MarkingSchemeQuestion(
        label: label is String ? label : '',
        expectedAnswerOrKeywords: expected is String ? expected : '',
        maxMarks: maxMarks is num ? maxMarks.toDouble() : 0,
      ));
    }
    if (questions.isEmpty) {
      throw const MarkingKeyGenerationUnavailable('No questions could be found on that document.');
    }

    final notes = responseData['notes'];
    final detectedTitle = responseData['detectedTitle'];
    return DerivedMarkingKey(
      questions: questions,
      notes: notes is String ? notes : '',
      detectedTitle: detectedTitle is String ? detectedTitle : '',
    );
  }
}
