import '../models/marking_scheme.dart';
import 'marking_scheme_repository.dart';

/// Finds locally-stored marking keys whose subject matches a given
/// subject name — feeds the "Reference: Assessment Content" section
/// appended to generated Lesson Plans and Schemes of Work (see
/// related_marking_key_section.dart), and is also the standing,
/// permanent mechanism by which every marking key ever saved (see
/// MarkingSchemeRepository.save — nothing bypasses that single choke
/// point) stays available to any AI feature that resolves content for a
/// subject/topic, per this app's own content-reuse policy: a marking key
/// is real, teacher-confirmed, already-structured Q&A content for a real
/// exam, so it is treated the same as any other Subject Content Database
/// material once saved — nothing further to "process" or re-index, since
/// the structured data already IS the compact form (no extra AI call
/// needed just to make it findable). Entirely offline: reads the same
/// on-device catalog AI-Assisted Marking already uses, no network call.
///
/// Matching is a simple case-insensitive, trimmed equality/substring
/// check — marking-key subject/topic names are free text a teacher typed
/// (see MarkingKeyDetailsFormScreen), not tied to the bundled syllabus's
/// exact naming, so an exact-match-only comparison would miss obvious
/// matches like "Maths" vs "Mathematics". Deliberately NOT fuzzy beyond
/// that (no typo-tolerance/stemming) — a wrong match here would show a
/// teacher irrelevant assessment content as if it were relevant, which
/// is worse than an occasional missed match.
class RelatedMarkingKeyFinder {
  RelatedMarkingKeyFinder({MarkingSchemeRepository? schemeRepository})
      : _schemeRepository = schemeRepository ?? MarkingSchemeRepository();

  final MarkingSchemeRepository _schemeRepository;

  static const _maxResults = 3;

  /// [topicName]/[subTopicName] are optional refinements, not a filter —
  /// a marking key derived from a full mock exam or past paper rarely
  /// maps to one bundled syllabus topic (see MarkingSchemeBuilderScreen's
  /// own doc comment on why subject/topic here is free text), so a
  /// scheme whose own topicName doesn't mention the given topic is still
  /// returned when there's a subject match and nothing more specific is
  /// available — it's just ranked behind schemes that also mention the
  /// topic, rather than excluded outright.
  Future<List<MarkingScheme>> find(String subjectName, {String? topicName, String? subTopicName}) async {
    final needle = subjectName.trim().toLowerCase();
    if (needle.isEmpty) return const [];

    final catalog = await _schemeRepository.loadCatalog();
    final subjectMatches = catalog.schemes.where((s) {
      final subject = s.subjectName.trim().toLowerCase();
      if (subject.isEmpty) return false;
      return subject == needle || subject.contains(needle) || needle.contains(subject);
    }).toList();

    final topicNeedles = [
      if (topicName != null && topicName.trim().isNotEmpty) topicName.trim().toLowerCase(),
      if (subTopicName != null && subTopicName.trim().isNotEmpty) subTopicName.trim().toLowerCase(),
    ];

    bool mentionsTopic(MarkingScheme s) {
      if (topicNeedles.isEmpty) return false;
      final haystack = [s.topicName, s.subTopicName ?? '', s.title].join(' ').toLowerCase();
      return topicNeedles.any((n) => haystack.contains(n));
    }

    subjectMatches.sort((a, b) {
      final topicRank = (mentionsTopic(b) ? 1 : 0) - (mentionsTopic(a) ? 1 : 0);
      if (topicRank != 0) return topicRank;
      return b.createdAt.compareTo(a.createdAt);
    });
    return subjectMatches.take(_maxResults).toList();
  }
}
