import 'package:cloud_functions/cloud_functions.dart';

import 'auth_service.dart';

/// Which of this app's real functions a parsed voice command is asking
/// for — mirrors the Cloud Function's own `VoiceCommandAction` union
/// exactly (see parseVoiceCommand's own doc comment in
/// firebase/functions/src/index.ts).
enum VoiceCommandAction {
  generateLessonPlan,
  generateSchemeOfWork,
  generateRecordOfWork,
  generateTeachingNotes,
  unrecognized;

  static VoiceCommandAction fromServer(String? value) => switch (value) {
        'generate_lesson_plan' => VoiceCommandAction.generateLessonPlan,
        'generate_scheme_of_work' => VoiceCommandAction.generateSchemeOfWork,
        'generate_record_of_work' => VoiceCommandAction.generateRecordOfWork,
        'generate_teaching_notes' => VoiceCommandAction.generateTeachingNotes,
        _ => VoiceCommandAction.unrecognized,
      };
}

/// The Cloud Function's raw structured understanding of one spoken
/// command — real fields only (never guessed/defaulted, see the
/// function's own doc comment); [VoiceCommandResolver] is what turns this
/// into an actual subject/grade/topic against this app's real bundled
/// data.
class ParsedVoiceCommand {
  final VoiceCommandAction action;
  final String? subjectName;
  final String? gradeName;
  final int? topicNumber;
  final int? weekNumber;
  final int? termNumber;
  final String summary;

  const ParsedVoiceCommand({
    required this.action,
    this.subjectName,
    this.gradeName,
    this.topicNumber,
    this.weekNumber,
    this.termNumber,
    required this.summary,
  });
}

/// Client side of the tap-to-talk voice command feature (2026-09-08, per
/// explicit request) — sends only a TEXT transcript (already produced
/// on-device by `speech_to_text`, see VoiceCommandScreen) to the
/// `parseVoiceCommand` Cloud Function for intent parsing. No audio is
/// ever recorded to a file or uploaded anywhere.
class VoiceCommandService {
  VoiceCommandService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  /// Throws on failure (offline, timeout, malformed response) — unlike
  /// the silent-best-effort AI enrichment services elsewhere in this app,
  /// a voice command IS the whole action the teacher just took, so a
  /// failure needs to be shown, not silently swallowed.
  Future<ParsedVoiceCommand> parse(String transcript) async {
    await AuthService.instance.ensureSignedIn();
    final callable = _functions.httpsCallable(
      'parseVoiceCommand',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call<Object?>({'transcript': transcript}).timeout(const Duration(seconds: 35));
    final data = result.data;
    if (data is! Map) {
      throw StateError('Unexpected response from the voice command service.');
    }
    return ParsedVoiceCommand(
      action: VoiceCommandAction.fromServer(data['action'] as String?),
      subjectName: data['subjectName'] as String?,
      gradeName: data['gradeName'] as String?,
      topicNumber: (data['topicNumber'] as num?)?.toInt(),
      weekNumber: (data['weekNumber'] as num?)?.toInt(),
      termNumber: (data['termNumber'] as num?)?.toInt(),
      summary: data['summary'] as String? ?? transcript,
    );
  }
}
