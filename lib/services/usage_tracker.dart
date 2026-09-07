import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One subject+grade/form combination's real usage on this device — how
/// many times it's been picked (any "Generate ..." function) and when it
/// was picked last. Ranking uses [count] first, [lastUsedAt] only to break
/// a tie, so a combination picked 20 times last month still outranks one
/// picked once yesterday — genuine habitual use, not just recency.
class UsageEntry {
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final int count;
  final DateTime lastUsedAt;

  const UsageEntry({
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.count,
    required this.lastUsedAt,
  });

  UsageEntry _bump() => UsageEntry(
        curriculumCode: curriculumCode,
        subjectCode: subjectCode,
        gradeLevel: gradeLevel,
        count: count + 1,
        lastUsedAt: DateTime.now(),
      );

  Map<String, dynamic> _toJson() => {
        'curriculumCode': curriculumCode,
        'subjectCode': subjectCode,
        'gradeLevel': gradeLevel,
        'count': count,
        'lastUsedAt': lastUsedAt.toIso8601String(),
      };

  static UsageEntry _fromJson(Map<String, dynamic> json) => UsageEntry(
        curriculumCode: json['curriculumCode'] as String,
        subjectCode: json['subjectCode'] as String,
        gradeLevel: json['gradeLevel'] as int,
        count: json['count'] as int,
        lastUsedAt: DateTime.parse(json['lastUsedAt'] as String),
      );
}

/// "Personalized shortcuts" (2026-09-08, per explicit request — one half of
/// "get smarter with more usage"): a plain, on-device, no-AI usage counter.
/// Every time a subject+grade/form is picked through
/// [SubjectGradeTopicPickerScreen] (any of "Generate Lesson Plan"/"Generate
/// Scheme of Work"/"Generate Record of Work"/Teaching Notes' browse path —
/// deliberately one shared counter across all of them, since a teacher's
/// own most-taught classes are the same regardless of which function they
/// opened), [recordPick] bumps that combination's count — that screen then
/// surfaces the top few as one-tap "Quick Picks" chips above the normal
/// CBC/OBC drill-down, skipping repeated Subject → Grade taps for whatever
/// a teacher actually uses most. Entirely local (shared_preferences, same
/// pattern as [LessonCheckpointRepository]) — no data ever leaves the
/// device for this.
class UsageTracker {
  static const _key = 'subject_grade_usage';

  Future<Map<String, UsageEntry>> _all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
    return decoded.map((k, v) => MapEntry(k, UsageEntry._fromJson(v as Map<String, dynamic>)));
  }

  Future<void> _persist(Map<String, UsageEntry> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(all.map((k, v) => MapEntry(k, v._toJson()))));
  }

  String _keyFor(String curriculumCode, String subjectCode, int gradeLevel) =>
      '$curriculumCode|$subjectCode|$gradeLevel';

  Future<void> recordPick({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
  }) async {
    final all = await _all();
    final key = _keyFor(curriculumCode, subjectCode, gradeLevel);
    final existing = all[key];
    all[key] = existing?._bump() ??
        UsageEntry(
          curriculumCode: curriculumCode,
          subjectCode: subjectCode,
          gradeLevel: gradeLevel,
          count: 1,
          lastUsedAt: DateTime.now(),
        );
    await _persist(all);
  }

  /// The top [limit] combinations by real usage — see [UsageEntry]'s own
  /// doc comment for the ranking rule. Empty on a fresh install/before
  /// anything's ever been picked, which callers should treat as "nothing
  /// to show yet," not an error.
  Future<List<UsageEntry>> topPicks({int limit = 5}) async {
    final all = (await _all()).values.toList()
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : b.lastUsedAt.compareTo(a.lastUsedAt);
      });
    return all.take(limit).toList();
  }
}
