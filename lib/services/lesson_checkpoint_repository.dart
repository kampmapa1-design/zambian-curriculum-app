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
