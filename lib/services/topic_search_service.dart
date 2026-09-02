import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import 'auth_service.dart';
import 'template_repository.dart';

/// One ranked hit from [TopicSearchService.searchLocal] — everything a
/// caller needs to both show the result (subject/grade/term/week/topic
/// text) and resolve it to the same `SchemeOfWorkEntry` shape every other
/// topic-picking path already returns.
class TopicSearchResult {
  final SyllabusTemplate template;
  final Term term;
  final SchemeOfWorkEntry entry;
  final double score;

  const TopicSearchResult({required this.template, required this.term, required this.entry, required this.score});
}

class TopicSearchUnavailable implements Exception {
  final String message;
  const TopicSearchUnavailable(this.message);
  @override
  String toString() => message;
}

/// Topic search, Method 2 of the three topic-selection strategies decided
/// on 2026-09-02 — a free-text shortcut layered ON TOP of (never instead
/// of) Method 1's Grade→Term→Week→Topic drill-down (see
/// topic_picker_flow.dart). [searchLocal] runs first, always: a plain
/// word-overlap match across every bundled subject/grade/topic/sub-topic
/// name, entirely on-device and free. Only when that comes up empty does
/// a caller reach for [searchWithAiAssist], which asks Gemini to narrow
/// down to a real subject/grade (never a topic — see
/// `matchTopicSearchQuery`'s own comment for why), after which the normal
/// real on-device topic list takes over again.
class TopicSearchService {
  TopicSearchService({TemplateRepository? repository, FirebaseFunctions? functions})
      : _repository = repository ?? TemplateRepository(),
        _functions = functions ?? FirebaseFunctions.instance;

  final TemplateRepository _repository;
  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  List<String> _words(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 1)
      .toList();

  /// Fraction of [query]'s distinct words that appear (as a substring
  /// either direction, so "reproduce"/"reproduction" still match) in
  /// [candidate]. 0 when either side has no usable words.
  double _overlapScore(List<String> queryWords, String candidate) {
    if (queryWords.isEmpty) return 0;
    final candidateWords = _words(candidate);
    if (candidateWords.isEmpty) return 0;
    var hits = 0;
    for (final q in queryWords) {
      if (candidateWords.any((c) => c.contains(q) || q.contains(c))) hits++;
    }
    return hits / queryWords.length;
  }

  /// Searches every bundled subject's real topics/sub-topics for [query],
  /// entirely on-device. Returns the best matches (score > 0), highest
  /// first — empty if nothing shares any real wording with [query].
  Future<List<TopicSearchResult>> searchLocal(String query) async {
    final queryWords = _words(query);
    if (queryWords.isEmpty) return const [];

    await _repository.ensureAllSeeded();
    final manifest = await _repository.loadManifest();

    final results = <TopicSearchResult>[];
    for (final manifestEntry in manifest) {
      final template = await _repository.loadSyllabus(
        curriculumCode: manifestEntry.curriculumCode,
        subjectCode: manifestEntry.subjectCode,
        gradeLevel: manifestEntry.gradeLevel,
      );
      if (template == null) continue;

      final subjectText = '${manifestEntry.curriculumName} ${manifestEntry.subjectName} ${manifestEntry.gradeName}';
      final subjectScore = _overlapScore(queryWords, subjectText);

      for (final term in template.terms) {
        for (final entry in _entriesForTerm(term)) {
          final topicScore = _overlapScore(queryWords, entry.title);
          final combined = subjectScore + topicScore * 2;
          if (combined <= 0.2) continue;
          results.add(TopicSearchResult(template: template, term: term, entry: entry, score: combined));
        }
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(25).toList();
  }

  List<SchemeOfWorkEntry> _entriesForTerm(Term term) => [
        for (final topic in term.topics)
          if (topic.subTopics.isEmpty)
            SchemeOfWorkEntry(
              weekNumber: topic.sequenceNumber,
              topic: topic,
              objectives: topic.objectives,
              competencies: topic.competencies,
            )
          else
            for (final subTopic in topic.subTopics)
              SchemeOfWorkEntry(
                weekNumber: subTopic.sequenceNumber,
                topic: topic,
                subTopic: subTopic,
                objectives: subTopic.objectives,
                competencies: subTopic.competencies,
              ),
      ];

  /// Called only when [searchLocal] finds nothing — asks Gemini to narrow
  /// [query] down to one real bundled subject/grade (never a topic), then
  /// loads and returns that template in full so the caller can hand it
  /// straight to the normal Term→Week→Topic picker. Null if the AI
  /// couldn't find a plausible match either.
  Future<SyllabusTemplate?> searchWithAiAssist(String query) async {
    if (!await isOnline) {
      throw const TopicSearchUnavailable("You're offline. Connect to the internet for AI-assisted search.");
    }
    await AuthService.instance.ensureSignedIn();
    await _repository.ensureAllSeeded();
    final manifest = await _repository.loadManifest();
    if (manifest.isEmpty) return null;

    final subjects = [
      for (final m in manifest) '${m.curriculumName} · ${m.subjectName} · ${m.gradeName}',
    ];

    final callable = _functions.httpsCallable(
      'matchTopicSearchQuery',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 25)),
    );
    try {
      final result = await callable.call<Map<Object?, Object?>>({'query': query, 'subjects': subjects});
      final matchedIndex = result.data['matchedIndex'];
      if (matchedIndex is! int || matchedIndex < 0 || matchedIndex >= manifest.length) return null;

      final matched = manifest[matchedIndex];
      return await _repository.loadSyllabus(
        curriculumCode: matched.curriculumCode,
        subjectCode: matched.subjectCode,
        gradeLevel: matched.gradeLevel,
      );
    } on FirebaseFunctionsException catch (e) {
      throw TopicSearchUnavailable(e.message ?? 'AI-assisted search failed.');
    }
  }
}
