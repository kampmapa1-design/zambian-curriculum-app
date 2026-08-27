/// The three stages a topic's lesson conceptually has — Introduction, Main
/// Body, Conclusion — used by the "Generate Lesson Plan" entry flow to ask
/// which part of the lesson to generate. This is a simplified, app-level
/// framing on top of the real CDC lesson plan template's progression stages
/// (which may have more than three — e.g. the bundled default also has
/// Exercise and Homework, both grouped under "Main Body"); [matchingIndices]
/// maps one of these three onto every real stage that belongs to it by name
/// so nothing in the sourced template itself is renamed or dropped.
enum LessonStage { introduction, development, conclusion }

extension LessonStageLabel on LessonStage {
  String get label => switch (this) {
        LessonStage.introduction => 'Introduction',
        LessonStage.development => 'Main Body',
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

  /// Every real progression-stage index that belongs to this conceptual
  /// stage — Introduction and Conclusion match by name, and Main Body picks
  /// up everything else (Development, Exercise, Homework, ...), so a lesson
  /// plan generated "at the Main Body stage" covers all of the lesson's
  /// actual working stages, not just one narrowly-named row. Falls back to
  /// every index if none match by name (e.g. a custom uploaded template).
  List<int> matchingIndices(List<String> progressionStages) {
    final indices = <int>[];
    for (var i = 0; i < progressionStages.length; i++) {
      final name = progressionStages[i].toLowerCase();
      final isIntroduction = name.contains('introduction');
      final isConclusion = name.contains('conclusion');
      final matches = switch (this) {
        LessonStage.introduction => isIntroduction,
        LessonStage.conclusion => isConclusion,
        LessonStage.development => !isIntroduction && !isConclusion,
      };
      if (matches) indices.add(i);
    }
    return indices.isEmpty ? [for (var i = 0; i < progressionStages.length; i++) i] : indices;
  }
}
