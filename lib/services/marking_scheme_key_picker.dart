import '../models/marking_scheme.dart';

/// Splits [schemes] into ones whose own subject name matches
/// [subjectName] (case/whitespace-insensitive) and everything else, each
/// list newest-first.
///
/// Real, reported bug (2026-09-05): a marking key's `subjectName` is
/// free text a teacher types (MarkingKeyDetailsFormScreen) — genuinely
/// reasonable choices like "History Paper 1" and "History Paper 2" for
/// two different real exam papers of the same bundled syllabus subject
/// ("History") never matched that subject's exact name, and starting a
/// new marking cohort filtered the marking-key list down to nothing,
/// reporting "no marking key uploaded" despite both being safely saved.
/// The fix isn't a smarter string match (any heuristic can still miss a
/// real name) — it's to never fully hide anything: every saved key is
/// always shown, with the ones matching the picked subject surfaced
/// first purely as a convenience, never as a filter that can silently
/// exclude a real one. See ScriptBatchCaptureScreen's own use of this.
({List<MarkingScheme> matching, List<MarkingScheme> other}) splitMarkingSchemesBySubjectMatch(
  List<MarkingScheme> schemes,
  String subjectName,
) {
  final normalized = subjectName.trim().toLowerCase();
  final matching = schemes.where((s) => s.subjectName.trim().toLowerCase() == normalized).toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final other = schemes.where((s) => s.subjectName.trim().toLowerCase() != normalized).toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return (matching: matching, other: other);
}
