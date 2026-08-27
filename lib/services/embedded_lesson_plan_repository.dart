import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/embedded_lesson_plan.dart';

/// Loads the bundled `assets/lesson_plans/*.json` sets (real, sanitized
/// lesson plans sourced from the user's own Drive documents — see each
/// file's `_source` field) and matches them against a topic/sub-topic a
/// teacher is browsing in "Generate Lesson Plan". Entirely on-device, no
/// network — same pattern as [TemplateRepository] for syllabi.
class EmbeddedLessonPlanRepository {
  static const _manifestPath = 'assets/lesson_plans/manifest.json';

  List<EmbeddedLessonPlanSet>? _cache;

  Future<List<EmbeddedLessonPlanSet>> _loadAll() async {
    if (_cache != null) return _cache!;
    final sets = <EmbeddedLessonPlanSet>[];
    try {
      final manifestRaw = await rootBundle.loadString(_manifestPath);
      final files = (jsonDecode(manifestRaw) as Map<String, dynamic>)['files'] as List;
      for (final file in files.cast<String>()) {
        final raw = await rootBundle.loadString('assets/lesson_plans/$file');
        sets.add(EmbeddedLessonPlanSet.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      }
    } catch (_) {
      // No embedded lesson plans bundled yet, or a malformed manifest —
      // the feature simply has nothing to offer, not a crash.
    }
    _cache = sets;
    return sets;
  }

  String _normalize(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Every embedded lesson plan matching this exact curriculum/subject/grade
  /// and topic name (sub-topic name too, when the topic has one) — usually
  /// zero (most topics have no embedded source) or several (one topic is
  /// often taught across multiple real lessons). Matching is name-based and
  /// case/whitespace-insensitive, since embedded sources use their own
  /// original wording rather than the bundled syllabus JSON's exact topic
  /// text.
  Future<List<EmbeddedLessonPlan>> find({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required String topicName,
    String? subtopicName,
  }) async {
    final sets = await _loadAll();
    final normalizedTopic = _normalize(topicName);
    final normalizedSubtopic = subtopicName == null ? null : _normalize(subtopicName);

    final matches = <EmbeddedLessonPlan>[];
    for (final set in sets) {
      if (set.curriculumCode != curriculumCode) continue;
      if (set.subjectCode != subjectCode) continue;
      if (!set.gradeLevels.contains(gradeLevel)) continue;

      for (final plan in set.lessonPlans) {
        if (plan.gradeLevel != null && plan.gradeLevel != gradeLevel) continue;
        if (_normalize(plan.topicName) != normalizedTopic) continue;
        if (normalizedSubtopic != null) {
          if (plan.subtopicName == null || _normalize(plan.subtopicName!) != normalizedSubtopic) continue;
        }
        matches.add(plan);
      }
    }
    return matches;
  }
}
