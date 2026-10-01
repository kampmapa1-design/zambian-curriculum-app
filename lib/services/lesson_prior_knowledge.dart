import '../models/scheme_of_work.dart';
import 'template_repository.dart';

/// "4. Prior / Pre-requisite Knowledge" (2026-09-27, per explicit request):
/// auto-filled from the real sub-topic that comes immediately BEFORE
/// [current] in this subject's own syllabus sequence (term/topic/sub-topic
/// order) — real, sourced content, never invented. Entirely offline: reads
/// the same local syllabus data [current] itself was built from.
///
/// Returns null for the syllabus's very first entry (nothing precedes it) or
/// if the syllabus can't be loaded — callers should leave the field for the
/// teacher to fill by hand in either case, exactly as before this existed.
Future<SchemeOfWorkEntry?> findPrecedingSyllabusEntry({
  required TemplateRepository templates,
  required String curriculumCode,
  required String subjectCode,
  required int gradeLevel,
  required SchemeOfWorkEntry current,
}) async {
  final template = await templates.loadSyllabus(
    curriculumCode: curriculumCode,
    subjectCode: subjectCode,
    gradeLevel: gradeLevel,
  );
  if (template == null) return null;

  final entries = allSchemeOfWorkEntries(template);
  final index = entries.indexWhere(
    (e) => e.topic.id == current.topic.id && e.subTopic?.id == current.subTopic?.id,
  );
  if (index <= 0) return null;
  return entries[index - 1];
}

/// Real outcomes for [entry] — objectives when present, else competencies.
/// Same rule used throughout the OBC lesson plan work (see
/// lesson_teaching_points.dart).
List<String> outcomesOf(SchemeOfWorkEntry entry) => entry.objectives.isNotEmpty
    ? [for (final o in entry.objectives) o.description]
    : [for (final c in entry.competencies) c.description];

/// The "4. Prior / Pre-requisite Knowledge" text for [preceding] (from
/// [findPrecedingSyllabusEntry]), or null when there's genuinely nothing to
/// ground it in — the syllabus's first entry, or one with no recorded
/// outcomes at all.
///
/// Capped at 2 points (2026-09-28, per explicit request: "prior knowledge on
/// lesson plans also should not mention more than 2 points") — this is meant
/// to be a brief reminder of what came before, not a restatement of the
/// entire preceding sub-topic's outcomes.
String? buildPriorKnowledgeText(SchemeOfWorkEntry? preceding) {
  if (preceding == null) return null;
  final outcomes = outcomesOf(preceding);
  if (outcomes.isEmpty) return null;
  final points = outcomes.length > 2 ? outcomes.take(2).toList() : outcomes;
  return 'Learners have already covered "${preceding.title}", where they were able to:\n'
      '${points.map((p) => '•  $p').join('\n')}';
}
