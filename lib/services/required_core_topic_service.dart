import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

/// One AI-researched topic for "Required Core Topics" — only produced for
/// a phrase [RequiredCoreTopicResolver] found nothing for on-device.
class RequiredCoreTopicAiResult {
  final String phrase;
  final String name;
  final String description;
  final List<String> competencies;
  final List<String> objectives;

  const RequiredCoreTopicAiResult({
    required this.phrase,
    required this.name,
    required this.description,
    required this.competencies,
    required this.objectives,
  });
}

class RequiredCoreTopicUnavailable implements Exception {
  final String message;
  const RequiredCoreTopicUnavailable(this.message);
  @override
  String toString() => message;
}

/// Client side of the `generateRequiredCoreTopics` Cloud Function — the
/// online, last-resort step of "Required Core Topics" (2026-09-12, per
/// explicit request), called only for phrases nothing on-device could
/// answer. See [RequiredCoreTopicResolver] for the full search order.
class RequiredCoreTopicService {
  RequiredCoreTopicService({FirebaseFunctions? functions}) : _providedFunctions = functions;

  final FirebaseFunctions? _providedFunctions;
  FirebaseFunctions get _functions => _providedFunctions ?? FirebaseFunctions.instance;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<List<RequiredCoreTopicAiResult>> generate({
    required List<String> phrases,
    required String subjectName,
    String? gradeName,
    String? curriculumName,
    String? syllabusContext,
    // Real, on-device material found for each phrase (same order,
    // parallel to [phrases]) — null/empty for a phrase with nothing
    // found locally, in which case the server researches it online
    // instead. Grounds the AI's writing either way; never a shortcut
    // that skips actually writing a proper outcome statement — see
    // RequiredCoreTopicResolver's own doc comment on the real bug this
    // fixes (a generic filler sentence instead of real content).
    List<String?>? localContexts,
  }) async {
    if (!await isOnline) {
      throw const RequiredCoreTopicUnavailable("You're offline. Connect to the internet to add required core topics.");
    }
    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable(
      'generateRequiredCoreTopics',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 170)),
    );
    Object? rawData;
    try {
      final result = await callable.call<Object?>({
        'phrases': phrases,
        if (localContexts != null) 'localContexts': localContexts,
        'subjectName': subjectName,
        if (gradeName != null) 'gradeName': gradeName,
        if (curriculumName != null) 'curriculumName': curriculumName,
        if (syllabusContext != null && syllabusContext.trim().isNotEmpty) 'syllabusContext': syllabusContext,
      });
      rawData = result.data;
    } on FirebaseFunctionsException catch (e) {
      throw RequiredCoreTopicUnavailable(e.message ?? 'Failed to research these topics.');
    }

    if (rawData is! Map || rawData['topics'] is! List) {
      throw const RequiredCoreTopicUnavailable('The response was in an unexpected format.');
    }
    final results = <RequiredCoreTopicAiResult>[];
    for (final raw in rawData['topics'] as List) {
      if (raw is! Map) continue;
      results.add(RequiredCoreTopicAiResult(
        phrase: raw['phrase'] is String ? raw['phrase'] as String : '',
        name: raw['name'] is String ? raw['name'] as String : '',
        description: raw['description'] is String ? raw['description'] as String : '',
        competencies: (raw['competencies'] is List ? raw['competencies'] as List : const []).whereType<String>().toList(),
        objectives: (raw['objectives'] is List ? raw['objectives'] as List : const []).whereType<String>().toList(),
      ));
    }
    return results;
  }
}
