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

  const DerivedMarkingKey({required this.questions, required this.notes});
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

  Future<DerivedMarkingKey> deriveFromText(String documentText, {required MarkingKeySourceType sourceType}) =>
      _derive({'questionPaperText': documentText, 'sourceType': sourceType.wireValue});

  Future<DerivedMarkingKey> deriveFromImages(List<File> pageFiles, {required MarkingKeySourceType sourceType}) async {
    final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
    return _derive({'pageImagesBase64': images, 'sourceType': sourceType.wireValue});
  }

  /// Same as [deriveFromImages], but for bytes already in hand (e.g. from
  /// a file_picker result whose `.path` may not be populated on every
  /// platform) rather than re-reading from a [File].
  Future<DerivedMarkingKey> deriveFromImageBytes(List<List<int>> imagesBytes, {required MarkingKeySourceType sourceType}) {
    final images = [for (final bytes in imagesBytes) base64Encode(bytes)];
    return _derive({'pageImagesBase64': images, 'sourceType': sourceType.wireValue});
  }

  Future<DerivedMarkingKey> _derive(Map<String, dynamic> data) async {
    if (!await isOnline) {
      throw const MarkingKeyGenerationUnavailable("You're offline. Connect to the internet to generate a marking key.");
    }

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable(
      'deriveMarkingKeyFromQuestionPaper',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 110)),
    );
    try {
      final result = await callable.call<Map<Object?, Object?>>(data);
      final questionsRaw = (result.data['questions'] as List?) ?? const [];
      final questions = [
        for (final q in questionsRaw.cast<Map<Object?, Object?>>())
          MarkingSchemeQuestion(
            label: q['label'] as String? ?? '',
            expectedAnswerOrKeywords: q['expectedAnswerOrKeywords'] as String? ?? '',
            maxMarks: ((q['maxMarks'] as num?) ?? 0).toDouble(),
          ),
      ];
      if (questions.isEmpty) {
        throw const MarkingKeyGenerationUnavailable('No questions could be found on that document.');
      }
      return DerivedMarkingKey(questions: questions, notes: result.data['notes'] as String? ?? '');
    } on FirebaseFunctionsException catch (e) {
      throw MarkingKeyGenerationUnavailable(e.message ?? 'Failed to generate a marking key.');
    }
  }
}
