/// The three stages a topic's lesson conceptually has — Introduction,
/// Lesson Development, Conclusion — used by the "Generate Lesson Plan"
/// entry flow to ask which part of the lesson to start from/resume at.
/// This is a simplified, app-level framing on top of the real CDC lesson
/// plan template's progression stages (which may have more than three —
/// e.g. the bundled default also has Exercise and Homework); [indexIn]
/// maps one of these three onto the closest real stage by name so nothing
/// in the sourced template itself is renamed or dropped.
enum LessonStage { introduction, development, conclusion }

extension LessonStageLabel on LessonStage {
  String get label => switch (this) {
        LessonStage.introduction => 'Introduction',
        LessonStage.development => 'Lesson Development',
        LessonStage.conclusion => 'Conclusion',
      };

  /// The best-matching index into a template's `progressionStages` for this
  /// conceptual stage, matched by name. Falls back to first/middle/last if
  /// the template's stage names don't literally say "introduction" etc.
  /// (e.g. a custom uploaded template with no progression stages at all —
  /// callers should check `progressionStages.isNotEmpty` first).
  int indexIn(List<String> progressionStages) {
    if (progressionStages.isEmpty) return 0;
    final keyword = switch (this) {
      LessonStage.introduction => 'introduction',
      LessonStage.development => 'development',
      LessonStage.conclusion => 'conclusion',
    };
    final match = progressionStages.indexWhere((s) => s.toLowerCase().contains(keyword));
    if (match != -1) return match;
    return switch (this) {
      LessonStage.introduction => 0,
      LessonStage.development => progressionStages.length ~/ 2,
      LessonStage.conclusion => progressionStages.length - 1,
    };
  }

  /// The reverse of [indexIn] — which conceptual stage a real progression
  /// stage index falls under, used to pre-select a stage in the picker
  /// when resuming a checkpoint saved at that index.
  static LessonStage fromIndex(int index, List<String> progressionStages) {
    final name = (index >= 0 && index < progressionStages.length) ? progressionStages[index].toLowerCase() : '';
    if (name.contains('introduction')) return LessonStage.introduction;
    if (name.contains('conclusion')) return LessonStage.conclusion;
    return LessonStage.development;
  }
}
