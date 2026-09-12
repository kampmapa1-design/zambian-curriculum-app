import '../models/scheme_of_work.dart';
import 'subject_content_repository.dart';
import 'template_repository.dart';
import 'text_excerpt_matching.dart';
import 'topic_search_service.dart';

/// What this app could already find on-device about a "Priority Content
/// Area" phrase (2026-09-12, per explicit request) — e.g. a teacher typing
/// "rise and fall of Shaka Zulu" while planning a lesson on the wider
/// "Mfecane" topic, to surface a sub-topic's content that would otherwise
/// stay buried inside the main topic. Searched in this order, cheapest
/// and most specific first: the CURRENT topic's own text, then every
/// other topic/sub-topic in the SAME subject's whole syllabus, then the
/// Subject Content Database (downloaded CDC materials). Only when none of
/// these find anything does [foundLocally] come back false — the caller
/// (generateLessonPlan, server-side) then falls back to a real online
/// search, never before.
class PriorityContentFindings {
  final String phrase;

  /// True when the phrase's own words already substantially appear in the
  /// CURRENT topic/sub-topic's own text — the lesson may already touch on
  /// it, but the teacher still gets the emphasis they asked for.
  final bool alreadyInCurrentTopic;

  /// A real syllabus entry (topic or sub-topic, in the SAME subject) whose
  /// own text matched the phrase — e.g. finding "Shaka" under a
  /// "Mfecane" -> "Rise and fall of Shaka Zulu" sub-topic.
  final String? syllabusEntryLabel;
  final String? syllabusExcerpt;

  /// The best-matching excerpt from the on-device Subject Content Database.
  final String? contentDbExcerpt;

  const PriorityContentFindings({
    required this.phrase,
    this.alreadyInCurrentTopic = false,
    this.syllabusEntryLabel,
    this.syllabusExcerpt,
    this.contentDbExcerpt,
  });

  bool get foundLocally =>
      alreadyInCurrentTopic || (syllabusExcerpt?.isNotEmpty ?? false) || (contentDbExcerpt?.isNotEmpty ?? false);

  /// Everything found, combined into one block of real text to ground the
  /// AI's writing — null when nothing local was found at all, in which
  /// case the server does one online search instead of using this.
  String? get combinedContext {
    if (!foundLocally) return null;
    final parts = <String>[];
    if (syllabusExcerpt != null && syllabusExcerpt!.trim().isNotEmpty) {
      parts.add(
          'From this syllabus\'s own "${syllabusEntryLabel ?? 'related topic'}": ${syllabusExcerpt!.trim()}');
    }
    if (contentDbExcerpt != null && contentDbExcerpt!.trim().isNotEmpty) {
      parts.add('From material already saved on this device: ${contentDbExcerpt!.trim()}');
    }
    if (parts.isEmpty && alreadyInCurrentTopic) {
      parts.add('Already touched on within this lesson\'s own topic content above.');
    }
    return parts.isEmpty ? null : parts.join('\n\n');
  }
}

class PriorityContentResolver {
  PriorityContentResolver({
    TemplateRepository? templateRepository,
    TopicSearchService? topicSearchService,
    SubjectContentRepository? subjectContentRepository,
  })  : _templates = templateRepository ?? TemplateRepository(),
        _topicSearch = topicSearchService ?? TopicSearchService(),
        _subjectContent = subjectContentRepository ?? SubjectContentRepository();

  final TemplateRepository _templates;
  final TopicSearchService _topicSearch;
  final SubjectContentRepository _subjectContent;

  Future<PriorityContentFindings> resolve({
    required String phrase,
    required String subjectName,
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required SchemeOfWorkEntry currentEntry,
  }) async {
    final phraseWords = keywordsOf(phrase);
    if (phraseWords.isEmpty) return PriorityContentFindings(phrase: phrase);

    // 1. Already within the current topic's own text?
    final currentText = [
      currentEntry.topic.name,
      currentEntry.subTopic?.name ?? '',
      currentEntry.topic.description ?? '',
      currentEntry.subTopic?.description ?? '',
      for (final c in currentEntry.competencies) c.description,
      for (final o in currentEntry.objectives) o.description,
    ].join(' ').toLowerCase();
    final alreadyInCurrentTopic = phraseWords.every(currentText.contains);

    // 2. The whole subject's syllabus, for a specific sub-topic elsewhere
    // in it that matches the phrase (e.g. "Shaka Zulu" under "Mfecane").
    String? syllabusLabel;
    String? syllabusExcerpt;
    try {
      final template = await _templates.loadSyllabus(
        curriculumCode: curriculumCode,
        subjectCode: subjectCode,
        gradeLevel: gradeLevel,
      );
      if (template != null) {
        final search = _topicSearch.searchWithinTemplate(template, phrase, limit: 1);
        if (search.results.isNotEmpty) {
          final hit = search.results.first.entry;
          final isSameEntry =
              hit.topic.id == currentEntry.topic.id && hit.subTopic?.id == currentEntry.subTopic?.id;
          if (!isSameEntry) {
            syllabusLabel = hit.subTopic != null ? '${hit.topic.name} — ${hit.subTopic!.name}' : hit.topic.name;
            syllabusExcerpt = [
              hit.topic.description,
              hit.subTopic?.description,
              for (final c in hit.competencies) c.description,
              for (final o in hit.objectives) o.description,
            ].where((s) => s != null && s.trim().isNotEmpty).join(' ');
          }
        }
      }
    } catch (_) {
      // On-device lookup only enriches this — never blocks lesson generation.
    }

    // 3. The Subject Content Database (downloaded CDC materials) —
    // same-subject hit preferred, any real hit otherwise.
    String? contentDbExcerpt;
    try {
      final hits = await _subjectContent.searchContent(phrase, maxResults: 5);
      SubjectContentSearchHit? best;
      for (final h in hits) {
        if (h.item.subjectName.toLowerCase() == subjectName.toLowerCase()) {
          best = h;
          break;
        }
      }
      best ??= hits.isNotEmpty ? hits.first : null;
      if (best != null) contentDbExcerpt = best.excerpt;
    } catch (_) {
      // Same — enrichment only.
    }

    return PriorityContentFindings(
      phrase: phrase,
      alreadyInCurrentTopic: alreadyInCurrentTopic,
      syllabusEntryLabel: syllabusLabel,
      syllabusExcerpt: syllabusExcerpt,
      contentDbExcerpt: contentDbExcerpt,
    );
  }
}
