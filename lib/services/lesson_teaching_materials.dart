import '../models/subject_content_item.dart';

/// "6. Teaching and Learning Materials / Resources" (2026-09-27, per
/// explicit request): auto-filled rather than left blank for the teacher to
/// type from scratch — every Zambian secondary classroom can be expected to
/// have these, the same "never invent equipment a typical classroom
/// wouldn't plausibly have" principle the AI prompt already applies (see
/// buildLessonPlanPrompt's own TLM instruction in firebase/functions).
const kStandardTeachingMaterials = ['Chalkboard', 'Textbook', 'Exercise books'];

/// [relatedMaterials] are the same real, bundled/downloaded material titles
/// already resolved for this subject and shown as reference chips on this
/// screen (see SubjectContentIndex.resolve).
///
/// Real bug fixed 2026-09-28 (reported: "form 1 materials being mentioned
/// among reference materials for a grade 10 subject lesson plan"): naming a
/// specific saved item's own title here — e.g. a bundled CBC "Form 1"
/// teaching module used only for on-device grounding — cites it as if it
/// were a genuine, openly quotable reference for a DIFFERENT curriculum and
/// grade, which it is not (the same non-disclosure rule already applied to
/// every AI grounding prompt in this app: "NEVER name or reference which
/// curriculum/module/revision it came from" — this field had been missing
/// it). [syllabusPlaceholder], when given (Grade 10-12/OBC lessons — see
/// lesson_plan_screen.dart), replaces [relatedMaterials] entirely with a
/// generic, safe citation ("Geography Grade 10-12 Syllabus") instead —
/// never a specific saved item's title, however relevant its content. Null
/// (every other template) keeps the previous behavior unchanged.
String buildTeachingMaterialsText(List<SubjectContentItem> relatedMaterials, {String? syllabusPlaceholder}) {
  if (syllabusPlaceholder != null) {
    return [syllabusPlaceholder, ...kStandardTeachingMaterials].join(', ');
  }
  final titles = <String>{for (final m in relatedMaterials) m.title.trim()}..removeWhere((t) => t.isEmpty);
  return [...titles, ...kStandardTeachingMaterials].join(', ');
}
