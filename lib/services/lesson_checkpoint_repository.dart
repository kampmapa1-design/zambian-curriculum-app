import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/lesson_checkpoint.dart';

/// Persists mid-lesson checkpoints (Stage 6: "Resume Lesson"), entirely
/// on-device via shared_preferences — one checkpoint per lesson, keyed by
/// [LessonCheckpoint.lessonKey], overwritten on every save.
class LessonCheckpointRepository {
  static const _key = 'lesson_checkpoints';

  Future<Map<String, LessonCheckpoint>> _all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
    return decoded.map((k, v) => MapEntry(k, LessonCheckpoint.fromJson(v as Map<String, dynamic>)));
  }

  Future<void> _persist(Map<String, LessonCheckpoint> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))));
  }

  Future<LessonCheckpoint?> find({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required int topicId,
    required int? subTopicId,
  }) async {
    final all = await _all();
    return all[LessonCheckpoint.keyFor(
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
      topicId: topicId,
      subTopicId: subTopicId,
    )];
  }

  /// The most recently saved checkpoint for this subject+grade, regardless
  /// of which topic/sub-topic it belongs to — used by the "Resume paused
  /// lesson" entry point, which doesn't ask the teacher to pick a topic
  /// first (that's the whole point of resuming).
  Future<LessonCheckpoint?> findMostRecentForSubject({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
  }) async {
    final all = await _all();
    final matches = all.values
        .where((c) =>
            c.curriculumCode == curriculumCode && c.subjectCode == subjectCode && c.gradeLevel == gradeLevel)
        .toList()
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return matches.isEmpty ? null : matches.first;
  }

  /// The single most recently saved checkpoint across EVERY subject/grade —
  /// 2026-09-08, for the voice-command "continue where I left off" /
  /// "resume my last lesson" action, which deliberately names no subject
  /// at all (that's the whole point of it). Null when nothing is paused
  /// anywhere.
  Future<LessonCheckpoint?> findMostRecentOverall() async {
    final all = await _all();
    if (all.isEmpty) return null;
    final matches = all.values.toList()..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return matches.first;
  }

  Future<void> save(LessonCheckpoint checkpoint) async {
    final all = await _all();
    all[checkpoint.lessonKey] = checkpoint;
    await _persist(all);
  }

  Future<void> clear({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required int topicId,
    required int? subTopicId,
  }) async {
    final all = await _all();
    all.remove(LessonCheckpoint.keyFor(
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
      topicId: topicId,
      subTopicId: subTopicId,
    ));
    await _persist(all);
  }
}
