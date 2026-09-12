import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import 'required_core_topic_service.dart';
import 'subject_content_repository.dart';
import 'topic_search_service.dart';

/// One resolved "Required Core Topic" (2026-09-12, per explicit request) —
/// a teacher-named topic ("rise and fall of Shaka Zulu") the generated
/// scheme didn't directly show, resolved into a real [SchemeOfWorkEntry]
/// ready to slot into the document.
class RequiredCoreTopicResult {
  final String phrase;
  final SchemeOfWorkEntry entry;

  /// True when [entry] is a REAL syllabus topic/sub-topic that already
  /// exists elsewhere in this subject (just not in this term's scheme) —
  /// its topic/sub-topic id is real, so lesson-history/progress logging
  /// treats it exactly like any other real topic. False means [entry]'s
  /// topic is synthetic (built from the Subject Content Database or AI
  /// research) and must be excluded from that logging — see
  /// SchemeOfWorkDocumentScreen's own use of this.
  final bool isRealSyllabusTopic;

  /// Where the content came from, for the confirmation shown to the
  /// teacher — never shown inside the generated document itself.
  final RequiredCoreTopicSource source;

  const RequiredCoreTopicResult({
    required this.phrase,
    required this.entry,
    required this.isRealSyllabusTopic,
    required this.source,
  });
}

enum RequiredCoreTopicSource { syllabus, contentDatabase, aiResearch }

/// Searches, for each phrase, in order — cheapest and most trustworthy
/// first: this subject's WHOLE syllabus (every term, not just the one
/// being scheduled — the whole point is surfacing content "hidden" inside
/// a bigger topic or a different term), then the on-device Subject
/// Content Database, then — only if neither finds anything — one real
/// online search via [RequiredCoreTopicService]. Entirely offline until
/// that last step.
class RequiredCoreTopicResolver {
  RequiredCoreTopicResolver({
    TopicSearchService? topicSearchService,
    SubjectContentRepository? subjectContentRepository,
    RequiredCoreTopicService? aiService,
  })  : _topicSearch = topicSearchService ?? TopicSearchService(),
        _subjectContent = subjectContentRepository ?? SubjectContentRepository(),
        _aiService = aiService ?? RequiredCoreTopicService();

  final TopicSearchService _topicSearch;
  final SubjectContentRepository _subjectContent;
  final RequiredCoreTopicService _aiService;

  int _syntheticIdCounter = -900000;
  int _nextSyntheticId() => _syntheticIdCounter--;

  /// [phrases] should already be split/trimmed/capped (see the screen's own
  /// comma-splitting) — up to 3, per explicit request. [existingEntries] is
  /// this term's current scheme, used only to avoid re-adding a real
  /// syllabus topic that's already in it.
  Future<List<RequiredCoreTopicResult>> resolve({
    required List<String> phrases,
    required SyllabusTemplate template,
    required List<SchemeOfWorkEntry> existingEntries,
  }) async {
    final results = <RequiredCoreTopicResult?>[for (final _ in phrases) null];
    final needsAi = <int>[];

    final existingIds = {for (final e in existingEntries) (e.topic.id, e.subTopic?.id)};

    for (var i = 0; i < phrases.length; i++) {
      final phrase = phrases[i];

      // 1. The whole subject syllabus — every term, so a topic "hidden"
      // under a bigger one, or scheduled in a different term, still
      // surfaces.
      final search = _topicSearch.searchWithinTemplate(template, phrase, limit: 1);
      if (search.results.isNotEmpty) {
        final hit = search.results.first.entry;
        if (!existingIds.contains((hit.topic.id, hit.subTopic?.id))) {
          results[i] = RequiredCoreTopicResult(
            phrase: phrase,
            entry: hit,
            isRealSyllabusTopic: true,
            source: RequiredCoreTopicSource.syllabus,
          );
          continue;
        }
      }

      // 2. The Subject Content Database.
      try {
        final hits = await _subjectContent.searchContent(phrase, maxResults: 3);
        if (hits.isNotEmpty) {
          final best = hits.first;
          final topic = Topic(
            id: _nextSyntheticId(),
            sequenceNumber: 0,
            name: _titleCase(phrase),
            description: best.excerpt,
          );
          results[i] = RequiredCoreTopicResult(
            phrase: phrase,
            entry: SchemeOfWorkEntry(weekNumber: 0, topic: topic, objectives: const [], competencies: const []),
            isRealSyllabusTopic: false,
            source: RequiredCoreTopicSource.contentDatabase,
          );
          continue;
        }
      } catch (_) {
        // Falls through to AI research below.
      }

      needsAi.add(i);
    }

    if (needsAi.isNotEmpty) {
      final aiResults = await _aiService.generate(
        phrases: [for (final i in needsAi) phrases[i]],
        subjectName: template.subject.name,
        gradeName: template.grade.name,
        curriculumName: template.curriculum.name,
        syllabusContext: _buildSyllabusContext(template),
      );
      for (final i in needsAi) {
        final phrase = phrases[i];
        final match = aiResults.where((r) => r.phrase.trim().toLowerCase() == phrase.trim().toLowerCase());
        final ai = match.isNotEmpty ? match.first : (aiResults.length == needsAi.length ? aiResults[needsAi.indexOf(i)] : null);
        if (ai == null || ai.name.trim().isEmpty) continue;
        final topic = Topic(
          id: _nextSyntheticId(),
          sequenceNumber: 0,
          name: ai.name.trim(),
          description: ai.description,
          competencies: [
            for (var c = 0; c < ai.competencies.length; c++)
              Competency(id: _nextSyntheticId(), sequenceNumber: c + 1, description: ai.competencies[c]),
          ],
          objectives: [
            for (var o = 0; o < ai.objectives.length; o++)
              LearningObjective(id: _nextSyntheticId(), sequenceNumber: o + 1, description: ai.objectives[o]),
          ],
        );
        results[i] = RequiredCoreTopicResult(
          phrase: phrase,
          entry: SchemeOfWorkEntry(
            weekNumber: 0,
            topic: topic,
            objectives: topic.objectives,
            competencies: topic.competencies,
          ),
          isRealSyllabusTopic: false,
          source: RequiredCoreTopicSource.aiResearch,
        );
      }
    }

    return results.whereType<RequiredCoreTopicResult>().toList();
  }

  /// A short, real sample of this syllabus's own topic names and a few
  /// objectives — grounds the AI research in what this subject/level
  /// actually covers, per explicit request ("look at what the syllabus
  /// mentions about those topics and its objectives").
  String _buildSyllabusContext(SyllabusTemplate template) {
    final topicNames = <String>[];
    final objectiveSamples = <String>[];
    for (final term in template.terms) {
      for (final topic in term.topics) {
        topicNames.add(topic.name);
        if (objectiveSamples.length < 6 && topic.objectives.isNotEmpty) {
          objectiveSamples.add(topic.objectives.first.description);
        }
        for (final sub in topic.subTopics) {
          topicNames.add(sub.name);
        }
      }
    }
    final parts = <String>[];
    if (topicNames.isNotEmpty) parts.add('Topics this syllabus covers: ${topicNames.take(25).join(', ')}.');
    if (objectiveSamples.isNotEmpty) parts.add('Example stated objectives: ${objectiveSamples.join(' ')}');
    return parts.join('\n');
  }

  String _titleCase(String phrase) => phrase
      .trim()
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
