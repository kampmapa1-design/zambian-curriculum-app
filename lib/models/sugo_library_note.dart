/// "Sugo Library" (owner request, 2026-09-29) — a learner-facing bank of
/// pre-generated bulletin-style topic notes, built entirely offline once
/// (see the Stage 2 batch generator, `tool/generate_sugo_library.dart`) so
/// reading a topic at runtime needs no live AI call at all — see
/// `SugoLibraryService`.
library;

/// How [SugoLibraryNote.notes] for one topic was produced — decides both
/// whether [questions] exist at all (only [aiCondensed] gets them, per the
/// owner's own spec: questions are generated "at the same time as" the AI
/// condensing call, at zero marginal extra cost, never as a separate
/// mechanical step) and what the Library UI should say about the content.
enum SugoLibrarySourceTier {
  /// An exact, curated embedded-lesson-plan match for this topic — real,
  /// already-structured content, mechanically reformatted into bullets with
  /// NO Gemini call at all.
  mechanical,

  /// Real source text existed (Subject Content Database or a bundled
  /// pamphlet excerpt) but needed condensing — ONE Gemini call, grounded in
  /// that excerpt plus the topic's own real syllabus competencies/
  /// objectives, never inventing beyond them.
  aiCondensed,

  /// No real source document at all for this topic — bare syllabus
  /// competencies/objectives alone aren't enough to honestly write up to
  /// 600 words of genuine notes from, so nothing is generated; the Library
  /// shows "Not yet available" rather than padding with invented content.
  unavailable;

  String get wireValue => switch (this) {
        SugoLibrarySourceTier.mechanical => 'mechanical',
        SugoLibrarySourceTier.aiCondensed => 'ai_condensed',
        SugoLibrarySourceTier.unavailable => 'unavailable',
      };

  static SugoLibrarySourceTier fromWire(String? value) => switch (value) {
        'mechanical' => SugoLibrarySourceTier.mechanical,
        'ai_condensed' => SugoLibrarySourceTier.aiCondensed,
        _ => SugoLibrarySourceTier.unavailable,
      };
}

/// One recall/practice question generated alongside a topic's notes (only
/// for [SugoLibrarySourceTier.aiCondensed] topics) — simple tap-to-reveal,
/// no scoring, self-check only (Stage 6).
class SugoLibraryQuestion {
  final String question;
  final String answer;

  const SugoLibraryQuestion({required this.question, required this.answer});

  Map<String, Object?> toMap() => {'q': question, 'a': answer};

  factory SugoLibraryQuestion.fromMap(Map<String, Object?> map) => SugoLibraryQuestion(
        question: map['q'] as String? ?? '',
        answer: map['a'] as String? ?? '',
      );
}

/// A stable, deterministic identity for one topic/sub-topic within a
/// curriculum/subject/grade — used as both the Firestore document id (see
/// [slug]) and the manifest's own key, so client and generator always agree
/// on which real syllabus entry a given note belongs to.
class SugoLibraryTopicId {
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final String topicName;
  final String? subTopicName;

  const SugoLibraryTopicId({
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.topicName,
    this.subTopicName,
  });

  static String _slugPart(String s) =>
      s.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  /// A Firestore-doc-id-safe, human-debuggable key — never regenerated
  /// differently for the same real topic, so a re-run of the batch
  /// generator always overwrites the same document rather than creating a
  /// duplicate.
  String get slug =>
      '${_slugPart(curriculumCode)}__${_slugPart(subjectCode)}__g${gradeLevel}__${_slugPart(topicName)}'
      '${subTopicName == null || subTopicName!.trim().isEmpty ? '' : '__${_slugPart(subTopicName!)}'}';
}

/// One topic's stored Library content (Firestore `sugoLibrary/{slug}`) —
/// written only by the Stage 2 batch generator via the owner-gated
/// `saveSugoLibraryTopic` Cloud Function, read directly by any signed-in
/// learner (mirrors the `appConfig/nationalExamTimetable` read/write split).
class SugoLibraryNote {
  final String topicName;
  final String? subTopicName;
  final List<String> notes;
  final List<SugoLibraryQuestion> questions;
  final SugoLibrarySourceTier sourceTier;

  /// A content-version hash of whatever real source text this note was
  /// built from (see `sugoLibraryContentVersion`) — compared against the
  /// manifest on the client to decide whether a re-download is needed.
  final String contentVersion;

  final DateTime? updatedAt;

  const SugoLibraryNote({
    required this.topicName,
    this.subTopicName,
    required this.notes,
    this.questions = const [],
    required this.sourceTier,
    required this.contentVersion,
    this.updatedAt,
  });

  Map<String, Object?> toMap() => {
        'topicName': topicName,
        if (subTopicName != null) 'subTopicName': subTopicName,
        'notes': notes,
        'questions': [for (final q in questions) q.toMap()],
        'sourceTier': sourceTier.wireValue,
        'contentVersion': contentVersion,
      };

  /// Parses either a plain JSON map (the local on-device cache file) or a
  /// Firestore document's own `data()` map (same field names either way —
  /// [SugoLibraryService] writes the cache straight from what Firestore
  /// returns, so one parser serves both).
  factory SugoLibraryNote.fromMap(Map<String, dynamic> map) => SugoLibraryNote(
        topicName: map['topicName'] as String? ?? '',
        subTopicName: map['subTopicName'] as String?,
        notes: (map['notes'] as List?)?.cast<String>() ?? const [],
        questions: (map['questions'] as List?)
                ?.map((q) => SugoLibraryQuestion.fromMap((q as Map).cast<String, Object?>()))
                .toList() ??
            const [],
        sourceTier: SugoLibrarySourceTier.fromWire(map['sourceTier'] as String?),
        contentVersion: map['contentVersion'] as String? ?? '',
      );
}
