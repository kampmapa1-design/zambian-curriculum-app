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

/// [MarkingKeyGenerationService.derive]'s result — AI-suggested questions
/// plus any notes worth a teacher's attention before trusting them (an
/// assumed mark allocation, an uncertain answer, etc).
class DerivedMarkingKey {
  final List<MarkingSchemeQuestion> questions;
  final String notes;

  const DerivedMarkingKey({required this.questions, required this.notes});
}

/// AI-Assisted Marking, Stage B — calls `deriveMarkingKeyFromQuestionPaper`
/// with a question paper's already-extracted text (see
/// SubjectContentExtractionService for the PDF-to-text step this expects
/// to run first) to get a draft marking key. Always a draft: the result is
/// meant to pre-fill MarkingSchemeBuilderScreen for a teacher to review and
/// edit, never saved directly — see the Cloud Function's own comment for
/// why (a question paper doesn't contain its own answers, so this is the
/// AI actually answering each question, not just reformatting the page).
class MarkingKeyGenerationService {
  MarkingKeyGenerationService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<DerivedMarkingKey> derive(String questionPaperText) async {
    if (!await isOnline) {
      throw const MarkingKeyGenerationUnavailable("You're offline. Connect to the internet to generate a marking key.");
    }

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable(
      'deriveMarkingKeyFromQuestionPaper',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 110)),
    );
    try {
      final result = await callable.call<Map<Object?, Object?>>({'questionPaperText': questionPaperText});
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
        throw const MarkingKeyGenerationUnavailable('No questions could be found on that paper.');
      }
      return DerivedMarkingKey(questions: questions, notes: result.data['notes'] as String? ?? '');
    } on FirebaseFunctionsException catch (e) {
      throw MarkingKeyGenerationUnavailable(e.message ?? 'Failed to generate a marking key.');
    }
  }
}
