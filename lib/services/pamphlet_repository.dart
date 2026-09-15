import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/pamphlet.dart';
import 'text_excerpt_matching.dart';

/// Loads the bundled `assets/pamphlets/*.json` set — real reference
/// pamphlets/notes (2026-09-15, per explicit request) too broad or
/// unstructured to model as a scheme of work, stored the same way marking
/// keys are made available to every generator (see [SubjectContentIndex])
/// but, unlike a marking key a teacher uploads themselves, never listed
/// or browsable anywhere in the app's own UI — purely background grounding
/// for teaching notes, lesson plans, schemes of work, exercises, and
/// marking-key generation. Entirely on-device/bundled, same pattern as
/// [EmbeddedLessonPlanRepository] and [TemplateRepository].
class PamphletRepository {
  static const _manifestPath = 'assets/pamphlets/manifest.json';

  List<Pamphlet>? _cache;

  Future<List<Pamphlet>> _loadAll() async {
    if (_cache != null) return _cache!;
    final pamphlets = <Pamphlet>[];
    try {
      final manifestRaw = await rootBundle.loadString(_manifestPath);
      final files = (jsonDecode(manifestRaw) as Map<String, dynamic>)['files'] as List;
      for (final file in files.cast<String>()) {
        final raw = await rootBundle.loadString('assets/pamphlets/$file');
        pamphlets.add(Pamphlet.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      }
    } catch (_) {
      // No pamphlets bundled yet, or a malformed manifest — this is
      // optional enrichment, never a reason to fail whatever generation
      // call is asking for it.
    }
    _cache = pamphlets;
    return pamphlets;
  }

  /// The best-matching excerpt across every pamphlet for [subjectName]
  /// (case-insensitive; optionally narrowed to [gradeLevel] when a
  /// pamphlet's own `gradeLevels` is specific), scored against
  /// [topicName]/[subTopicName] keywords the same way
  /// SubjectContentRepository.findRelevantExcerpt already works. With no
  /// topic given, returns a capped excerpt of the single longest-matching
  /// pamphlet instead, for callers wanting general subject grounding
  /// (e.g. Scheme of Work content fill) rather than one topic. Null when
  /// nothing bundled matches this subject at all.
  Future<String?> findRelevantExcerpt({
    required String subjectName,
    int? gradeLevel,
    String? topicName,
    String? subTopicName,
  }) async {
    final all = await _loadAll();
    final normalizedSubject = subjectName.trim().toLowerCase();
    final candidates = all.where((p) {
      if (p.subjectName.trim().toLowerCase() != normalizedSubject) return false;
      if (gradeLevel != null && p.gradeLevels.isNotEmpty && !p.gradeLevels.contains(gradeLevel)) return false;
      return true;
    }).toList();
    if (candidates.isEmpty) return null;

    if (topicName == null) {
      final longest = candidates.reduce((a, b) => a.fullText.length >= b.fullText.length ? a : b);
      return capExcerptWords(longest.fullText, 350);
    }

    final keywords = keywordsOf('$topicName ${subTopicName ?? ''}');
    String? best;
    var bestScore = 0;
    for (final pamphlet in candidates) {
      final match = bestExcerptFor(pamphlet.fullText, keywords);
      if (match != null && match.score > bestScore) {
        bestScore = match.score;
        best = match.excerpt;
      }
    }
    return best;
  }
}
