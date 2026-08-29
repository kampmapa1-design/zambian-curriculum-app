import '../models/marking_scheme.dart';
import 'marking_scheme_repository.dart';

/// Finds locally-stored marking keys whose subject matches a given
/// subject name — feeds the "Reference: Assessment Content" section
/// appended to generated Lesson Plans and Schemes of Work (see
/// related_marking_key_section.dart). Entirely offline: reads the same
/// on-device catalog AI-Assisted Marking already uses, no network call.
///
/// Matching is a simple case-insensitive, trimmed equality/substring
/// check — marking-key subject names are free text a teacher typed (see
/// MarkingKeyDetailsFormScreen), not tied to the bundled syllabus's exact
/// subject naming, so an exact-match-only comparison would miss obvious
/// matches like "Maths" vs "Mathematics". Deliberately NOT fuzzy beyond
/// that (no typo-tolerance/stemming) — a wrong match here would show a
/// teacher irrelevant assessment content as if it were relevant, which
/// is worse than an occasional missed match.
class RelatedMarkingKeyFinder {
  RelatedMarkingKeyFinder({MarkingSchemeRepository? schemeRepository})
      : _schemeRepository = schemeRepository ?? MarkingSchemeRepository();

  final MarkingSchemeRepository _schemeRepository;

  static const _maxResults = 3;

  Future<List<MarkingScheme>> find(String subjectName) async {
    final needle = subjectName.trim().toLowerCase();
    if (needle.isEmpty) return const [];

    final catalog = await _schemeRepository.loadCatalog();
    final matches = catalog.schemes.where((s) {
      final subject = s.subjectName.trim().toLowerCase();
      if (subject.isEmpty) return false;
      return subject == needle || subject.contains(needle) || needle.contains(subject);
    }).toList();

    matches.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return matches.take(_maxResults).toList();
  }
}
