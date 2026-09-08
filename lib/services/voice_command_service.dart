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
  // Everything below is 2026-09-08, a follow-up batch per explicit request
  // (see VoiceCommandResolver for how each one actually resolves against
  // this app's real data).
  /// A LOOKUP, not yet a generate command — "which topic can I find X in"
  /// (see [ParsedVoiceCommand.topicKeyword]). Resolves against one real
  /// subject's bundled content and hands the teacher back either a single
  /// precise topic or a short activatable list to pick from, rather than
  /// assuming which one they meant or what to do with it next.
  findTopic,
  openMarking,
  openClassRoster,
  checkCdcMaterials,
  resumeLesson,
  unrecognized;

  static VoiceCommandAction fromServer(String? value) => switch (value) {
        'generate_lesson_plan' => VoiceCommandAction.generateLessonPlan,
        'generate_scheme_of_work' => VoiceCommandAction.generateSchemeOfWork,
        'generate_record_of_work' => VoiceCommandAction.generateRecordOfWork,
        'generate_teaching_notes' => VoiceCommandAction.generateTeachingNotes,
        'find_topic' => VoiceCommandAction.findTopic,
        'open_marking' => VoiceCommandAction.openMarking,
        'open_class_roster' => VoiceCommandAction.openClassRoster,
        'check_cdc_materials' => VoiceCommandAction.checkCdcMaterials,
        'resume_lesson' => VoiceCommandAction.resumeLesson,
        _ => VoiceCommandAction.unrecognized,
      };
}

/// The Cloud Function's raw structured understanding of one spoken
/// command — real fields only (never guessed/defaulted, see the
/// function's own doc comment); [VoiceCommandResolver] is what turns this
/// into an actual subject/grade/topic/class against this app's real
/// bundled data.
class ParsedVoiceCommand {
  final VoiceCommandAction action;
  final String? subjectName;
  final String? gradeName;
  final int? topicNumber;
  final int? weekNumber;
  final int? termNumber;

  /// A real content phrase describing a topic by WHAT it covers (e.g.
  /// "parable of talents", "photosynthesis") rather than by number —
  /// 2026-09-08, per explicit request for a more precise, content-aware
  /// way to call up a topic by voice. Settable on any action, not just
  /// [VoiceCommandAction.findTopic] — a teacher can just as well say
  /// "make a lesson plan on the parable of talents" directly.
  final String? topicKeyword;

  /// The specific class named (e.g. "Grade 10A"), only ever set for
  /// [VoiceCommandAction.openClassRoster] — a real roster/class in the
  /// Grade Teacher pipeline, distinct from [subjectName]/[gradeName].
  final String? className;

  final String summary;

  const ParsedVoiceCommand({
    required this.action,
    this.subjectName,
    this.gradeName,
    this.topicNumber,
    this.weekNumber,
    this.termNumber,
    this.topicKeyword,
    this.className,
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
      topicKeyword: data['topicKeyword'] as String?,
      className: data['className'] as String?,
      summary: data['summary'] as String? ?? transcript,
    );
  }
}
