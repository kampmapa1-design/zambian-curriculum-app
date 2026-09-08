import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One real correction a teacher made to an AI-graded answer — the marks
/// AI actually awarded vs. what the teacher corrected them to, for a real
/// answer on a real script. See [MarkingCorrectionRepository]'s own doc
/// comment for how this feeds back into future grading.
class MarkingCorrection {
  final String questionLabel;
  final double maxMarks;
  final double aiMarks;
  final double correctedMarks;

  /// Truncated (see [MarkingCorrectionRepository.record]) — enough for the
  /// grading prompt to recognize "an answer like this", not the full
  /// verbatim transcript kept indefinitely.
  final String answerExcerpt;
  final DateTime recordedAt;

  const MarkingCorrection({
    required this.questionLabel,
    required this.maxMarks,
    required this.aiMarks,
    required this.correctedMarks,
    required this.answerExcerpt,
    required this.recordedAt,
  });

  Map<String, dynamic> toJson() => {
        'questionLabel': questionLabel,
        'maxMarks': maxMarks,
        'aiMarks': aiMarks,
        'correctedMarks': correctedMarks,
        'answerExcerpt': answerExcerpt,
        'recordedAt': recordedAt.toIso8601String(),
      };

  static MarkingCorrection fromJson(Map<String, dynamic> json) => MarkingCorrection(
        questionLabel: json['questionLabel'] as String,
        maxMarks: (json['maxMarks'] as num).toDouble(),
        aiMarks: (json['aiMarks'] as num).toDouble(),
        correctedMarks: (json['correctedMarks'] as num).toDouble(),
        answerExcerpt: json['answerExcerpt'] as String,
        recordedAt: DateTime.parse(json['recordedAt'] as String),
      );

  Map<String, dynamic> toCloudFunctionHint() => {
        'questionLabel': questionLabel,
        'maxMarks': maxMarks,
        'aiMarks': aiMarks,
        'correctedMarks': correctedMarks,
        'answerExcerpt': answerExcerpt,
      };
}

/// "Learn from AI-marking corrections" (2026-09-08, per explicit request,
/// clarified via AskUserQuestion — the other half of "get smarter with
/// more usage"): whenever a teacher changes the marks AI awarded on a
/// question during review (see MarkingReviewScreen._confirmAndFinish —
/// [GradedAnswer.teacherEdited] already flags exactly this), that real
/// correction is recorded here, keyed by subject. The most recent ones
/// for a script's own subject are then handed BACK into
/// [MarkingGradingService.grade] as grounding for future scripts of that
/// same subject — see `gradeMarkingScript`'s own `priorCorrections`
/// parameter in firebase/functions/src/index.ts for exactly how they're
/// used (a calibration hint, never ground truth for any specific new
/// answer). Entirely on-device (shared_preferences, same pattern as
/// [UsageTracker]/[LessonCheckpointRepository]) — corrections never leave
/// the device except as short excerpts sent alongside a NEW grading
/// request for the SAME subject, the same way every other real script
/// content already does.
class MarkingCorrectionRepository {
  static const _key = 'marking_corrections_by_subject';

  /// Kept per subject — recent, real corrections for OTHER subjects would
  /// only dilute (or actively mislead) a subject-specific calibration
  /// signal.
  static const _maxPerSubject = 15;
  static const _maxExcerptChars = 200;

  Future<Map<String, List<MarkingCorrection>>> _all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
    return decoded.map((subject, list) => MapEntry(
          subject,
          (list as List).map((e) => MarkingCorrection.fromJson((e as Map).cast<String, dynamic>())).toList(),
        ));
  }

  Future<void> _persist(Map<String, List<MarkingCorrection>> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(all.map((subject, list) => MapEntry(subject, list.map((c) => c.toJson()).toList()))),
    );
  }

  String _normalizeSubject(String subjectName) => subjectName.trim().toLowerCase();

  /// Records one real correction. [answerExcerpt] is truncated to a short
  /// length here (not kept as a full verbatim transcript indefinitely) —
  /// enough context for the grading prompt, not a growing archive of a
  /// student's own full written answers.
  Future<void> record({
    required String subjectName,
    required String questionLabel,
    required double maxMarks,
    required double aiMarks,
    required double correctedMarks,
    required String answerExcerpt,
  }) async {
    if (aiMarks == correctedMarks) return; // not actually a correction
    final all = await _all();
    final key = _normalizeSubject(subjectName);
    final list = [...(all[key] ?? const <MarkingCorrection>[])];
    final excerpt =
        answerExcerpt.trim().length <= _maxExcerptChars ? answerExcerpt.trim() : '${answerExcerpt.trim().substring(0, _maxExcerptChars)}…';
    list.insert(
      0,
      MarkingCorrection(
        questionLabel: questionLabel,
        maxMarks: maxMarks,
        aiMarks: aiMarks,
        correctedMarks: correctedMarks,
        answerExcerpt: excerpt,
        recordedAt: DateTime.now(),
      ),
    );
    all[key] = list.take(_maxPerSubject).toList();
    await _persist(all);
  }

  /// The most recent corrections for [subjectName] — empty for a subject
  /// with no real corrections yet, which callers should treat as "nothing
  /// to add," not an error.
  Future<List<MarkingCorrection>> recentFor(String subjectName) async {
    final all = await _all();
    return all[_normalizeSubject(subjectName)] ?? const [];
  }
}
