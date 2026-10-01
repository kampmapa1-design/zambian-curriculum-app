/// Real, generic references every subject genuinely has (owner request,
/// 2026-09-28: "always also automatically include suitable references...
/// 'Teachers' Guide for [Subject]' and 'Syllabus for [Subject]'... curriculum
/// whether OBC or CBC curriculum can always be mentioned for any subject").
/// Deliberately generic, not a specific invented title/author/ISBN — this
/// project's own sourcing-integrity rule forbids fabricating a SPECIFIC
/// citation, but "the syllabus" and "the teachers' guide" are real category-
/// level sources every real subject has, so naming them generically is
/// truthful, not a fabrication.
List<String> guaranteedSubjectReferences({required String subjectName, required bool isObc}) {
  final subject = subjectName.trim().isEmpty ? 'the Subject' : subjectName.trim();
  final curriculum = isObc ? 'OBC' : 'CBC';
  return [
    "Teachers' Guide for $subject",
    'Syllabus for $subject ($curriculum Curriculum)',
  ];
}

/// The full References field text for a Lesson Plan or Scheme of Work:
/// [curated] (e.g. a syllabus entry's own real, sourced references, when
/// any exist) kept first and never dropped, with [guaranteedSubjectReferences]
/// always appended after it — so the field is NEVER blank, and always
/// carries 2 (no curated content) or 3 (curated + the two generic ones)
/// real entries, never a fabricated one. Skips a generic line only if
/// [curated] already plainly mentions it, to avoid a near-duplicate.
String buildLessonPlanReferencesText({
  required String? curated,
  required String subjectName,
  required bool isObc,
}) {
  final lines = <String>[];
  final trimmedCurated = curated?.trim() ?? '';
  if (trimmedCurated.isNotEmpty) lines.add(trimmedCurated);
  for (final generic in guaranteedSubjectReferences(subjectName: subjectName, isObc: isObc)) {
    if (!lines.any((l) => l.toLowerCase().contains(generic.toLowerCase()))) {
      lines.add(generic);
    }
  }
  return lines.join('\n');
}
