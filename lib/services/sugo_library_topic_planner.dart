import '../models/embedded_lesson_plan.dart';
import '../models/sugo_library_note.dart';
import 'senior_secondary_content_filter.dart';
import 'sugo_library_content_version.dart';

/// Sugo Library Stage 2 (owner request, 2026-09-29) — the pure "what should
/// happen for this one topic" decision, entirely offline/no network: given
/// whatever real source this app already has on-device for a topic, decide
/// which of the three tiers applies (see [SugoLibrarySourceTier]) and either
/// produce the finished [SugoLibraryNote] directly (tiers a/c — mechanical
/// reformatting or "unavailable", neither needs Gemini) or a
/// [SugoLibraryCondensingRequest] describing exactly what an AI call would
/// need to produce tier (b)'s notes+questions — the actual network/auth
/// call is a separate concern this file never touches.
sealed class SugoLibraryTopicPlan {
  const SugoLibraryTopicPlan();
}

/// Tiers (a) and (c): nothing further needed — [note] is the final,
/// ready-to-save content.
class SugoLibraryReadyNote extends SugoLibraryTopicPlan {
  final SugoLibraryNote note;
  const SugoLibraryReadyNote(this.note);
}

/// Tier (b): real source exists but needs condensing — everything a
/// Gemini call needs to produce grounded notes+questions, with no
/// invented content beyond what's listed here.
class SugoLibraryCondensingRequest extends SugoLibraryTopicPlan {
  final SugoLibraryTopicId topicId;
  final String subjectName;
  final String curriculumLabel;
  final String groundingExcerpt;
  final List<String> competencies;
  final List<String> objectives;
  final int wordCap;

  const SugoLibraryCondensingRequest({
    required this.topicId,
    required this.subjectName,
    required this.curriculumLabel,
    required this.groundingExcerpt,
    required this.competencies,
    required this.objectives,
    required this.wordCap,
  });
}

const _defaultWordCap = 600;

/// Scales the notes word cap down for thin source material, per the owner's
/// own spec ("up to 600 words, scaled down where less source material
/// exists") — never pads a short real excerpt out to a fixed length by
/// asking the AI to invent filler.
int scaledSugoLibraryWordCap(String excerpt) {
  final sourceWords = excerpt.trim().isEmpty ? 0 : excerpt.trim().split(RegExp(r'\s+')).length;
  if (sourceWords >= 400) return _defaultWordCap;
  if (sourceWords < 60) return 150;
  return (sourceWords * 1.5).round().clamp(150, _defaultWordCap);
}

/// Tier (a): an exact embedded-lesson-plan match — real, already-structured
/// content, reformatted into bullets with NO Gemini call. Deliberately no
/// questions (only tier (b) gets them — see [SugoLibrarySourceTier]'s own
/// doc comment for why: generating them is only zero-marginal-cost when
/// riding along an AI call already being made).
SugoLibraryNote mechanicalSugoLibraryNote(
  SugoLibraryTopicId topicId,
  List<EmbeddedLessonPlan> plans, {
  required bool isSeniorSecondary,
}) {
  final lines = <String>[];
  final sourceParts = <String>[];
  for (final plan in plans) {
    final point = plan.majorLearningPoint?.trim();
    if (point != null && point.isNotEmpty) {
      lines.add(point);
      sourceParts.add(point);
    }
    for (final objective in plan.objectives) {
      final trimmed = objective.trim();
      if (trimmed.isEmpty) continue;
      lines.add(trimmed);
      sourceParts.add(trimmed);
    }
    for (final row in plan.progression) {
      final text = row.teacherRole?.trim();
      if (text != null && text.isNotEmpty) {
        lines.add(text);
        sourceParts.add(text);
      }
    }
  }
  final deduped = <String>{...lines}.toList();
  final cleaned = isSeniorSecondary
      ? deduped.map(cleanGeneratedText).where((l) => l.trim().isNotEmpty).toList()
      : deduped;
  return SugoLibraryNote(
    topicName: topicId.topicName,
    subTopicName: topicId.subTopicName,
    notes: cleaned,
    sourceTier: SugoLibrarySourceTier.mechanical,
    contentVersion: sugoLibraryContentVersion(sourceParts),
  );
}

/// The single entry point: given everything this app already knows
/// on-device about one topic (already loaded by the caller — this function
/// does no I/O of its own, so it's directly unit-testable), decide which
/// tier applies.
///
/// [embeddedMatches] empty and [groundingExcerpt] null means genuinely no
/// real source at all — bare syllabus competencies/objectives alone aren't
/// treated as "source content" here (see [SugoLibrarySourceTier.unavailable]'s
/// own doc comment): they're too thin to honestly write up to 600 words of
/// real notes from without padding.
SugoLibraryTopicPlan planSugoLibraryTopic({
  required SugoLibraryTopicId topicId,
  required String subjectName,
  required String curriculumCode,
  required List<EmbeddedLessonPlan> embeddedMatches,
  String? groundingExcerpt,
  List<String> competencies = const [],
  List<String> objectives = const [],
}) {
  final isSeniorSecondary = isSeniorSecondaryCurriculum(curriculumCode);

  if (embeddedMatches.isNotEmpty) {
    return SugoLibraryReadyNote(
      mechanicalSugoLibraryNote(topicId, embeddedMatches, isSeniorSecondary: isSeniorSecondary),
    );
  }

  final excerpt = groundingExcerpt?.trim();
  if (excerpt != null && excerpt.isNotEmpty) {
    return SugoLibraryCondensingRequest(
      topicId: topicId,
      subjectName: subjectName,
      curriculumLabel: isSeniorSecondary ? 'OBC' : 'CBC',
      groundingExcerpt: excerpt,
      competencies: competencies,
      objectives: objectives,
      wordCap: scaledSugoLibraryWordCap(excerpt),
    );
  }

  return SugoLibraryReadyNote(
    SugoLibraryNote(
      topicName: topicId.topicName,
      subTopicName: topicId.subTopicName,
      notes: const [],
      sourceTier: SugoLibrarySourceTier.unavailable,
      contentVersion: sugoLibraryContentVersion(const []),
    ),
  );
}
