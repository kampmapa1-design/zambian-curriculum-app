import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

/// One row of a Scheme of Work draft that genuinely has no real sourced
/// content for one or both of its Specific Competence/Outcome and
/// Learning Activities columns — see [SchemeOfWorkAiContentService.generate]'s
/// own doc comment for exactly when this applies.
class ThinSchemeOfWorkRow {
  final String id;
  final String topicName;
  final String? subTopicName;
  final String? existingDescription;
  final bool needsSpecificCompetence;
  final bool needsLearningActivities;

  const ThinSchemeOfWorkRow({
    required this.id,
    required this.topicName,
    this.subTopicName,
    this.existingDescription,
    required this.needsSpecificCompetence,
    required this.needsLearningActivities,
  });
}

/// AI-generated content for one [ThinSchemeOfWorkRow] — either field may be
/// empty if that row didn't need it.
class SchemeOfWorkAiContent {
  final String specificCompetence;
  final String learningActivities;

  const SchemeOfWorkAiContent({this.specificCompetence = '', this.learningActivities = ''});
}

/// Fills the real, common gap where a bundled syllabus has a genuine topic/
/// sub-topic but no real Specific Competence/Outcome or Learning Activities
/// content sourced for it yet — grounded strictly in that real topic's own
/// name/description, the same way Lesson Plan generation grounds itself in
/// real syllabus context (see generateLessonPlan's own Cloud Function
/// comment). A real, richer sourced SCHEME of work is always used first
/// when this app has one; this only ever runs for what's left genuinely
/// empty after that.
///
/// **Standing design choices, deliberate**:
/// - Batched: one Gemini call covers every thin row in a whole document
///   (up to 20 — a full scheme has at most 11 real content rows), never
///   one call per row, so generating one scheme never costs more than
///   generating one lesson plan already does (see the app's own Gemini
///   cost-consciousness precedent).
/// - Silent, best-effort, never blocking: offline, or any failure, simply
///   returns an empty result (see [generate]'s catch-all) rather than
///   throwing — Scheme of Work generation is an offline-first feature
///   (see SubjectContentIndex's own doc comment on why), and this is
///   purely an opportunistic enrichment layered on top of it, never a
///   requirement. The caller always has today's existing fallback
///   (a blank cell, or the topic/sub-topic's own description) to show
///   when this returns nothing.
class SchemeOfWorkAiContentService {
  SchemeOfWorkAiContentService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// Returns a map of row id -> generated content for every row that could
  /// be generated. Never throws — any failure (offline, timeout, malformed
  /// response) simply yields an empty map, since this is always an
  /// optional enrichment layered on top of an already-complete document.
  Future<Map<String, SchemeOfWorkAiContent>> generate({
    required List<ThinSchemeOfWorkRow> rows,
    required String subjectName,
    required String gradeName,
    required String curriculumName,
  }) async {
    if (rows.isEmpty) return const {};
    try {
      if (!await isOnline) return const {};
      await AuthService.instance.ensureSignedIn();

      final callable = _functions.httpsCallable(
        'generateSchemeOfWorkContent',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 110)),
      );
      final result = await callable.call<Object?>({
        'subjectName': subjectName,
        'gradeName': gradeName,
        'curriculumName': curriculumName,
        'items': [
          for (final r in rows)
            {
              'id': r.id,
              'topicName': r.topicName,
              if (r.subTopicName != null) 'subTopicName': r.subTopicName,
              if (r.existingDescription != null) 'existingDescription': r.existingDescription,
              'needsSpecificCompetence': r.needsSpecificCompetence,
              'needsLearningActivities': r.needsLearningActivities,
            },
        ],
      }).timeout(const Duration(seconds: 115));

      final rawData = result.data;
      if (rawData is! Map) return const {};
      final itemsRaw = rawData['items'];
      if (itemsRaw is! List) return const {};

      final out = <String, SchemeOfWorkAiContent>{};
      for (final item in itemsRaw) {
        if (item is! Map) continue;
        final id = item['id'];
        if (id is! String) continue;
        final specificCompetence = item['specificCompetence'];
        final learningActivities = item['learningActivities'];
        out[id] = SchemeOfWorkAiContent(
          specificCompetence: specificCompetence is String ? specificCompetence.trim() : '',
          learningActivities: learningActivities is String ? learningActivities.trim() : '',
        );
      }
      return out;
    } catch (_) {
      // Best-effort only — see this class's own doc comment. A teacher
      // still gets a complete, exportable scheme either way.
      return const {};
    }
  }
}
