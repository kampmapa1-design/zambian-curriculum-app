import '../models/embedded_lesson_plan.dart';
import '../models/syllabus_models.dart';

/// Builds a real scheme-of-work [Topic] for a confirmed Fine Tune selection
/// straight from the real embedded lesson plans that back it (Embedded
/// Content Search Stage 8, 2026-09-22) — no AI call, since this is already
/// real, teacher-authored content sourced from the user's own Drive
/// documents (see each assets/lesson_plans/*.json file's own `_source`
/// field). Mirrors RequiredCoreTopicResolver's own synthetic-topic shape
/// (a negative id — never a real database row) so it slots into the exact
/// same insertion logic Required Core Topics already uses.
class FineTuneTopicBuilder {
  const FineTuneTopicBuilder();

  static final _competenceLabel = RegExp(r'^(general|specific)\s+competence', caseSensitive: false);

  Topic build({
    required String topicName,
    required String subtopicName,
    required List<EmbeddedLessonPlan> plans,
    required int Function() nextSyntheticId,
  }) {
    String? description;
    for (final plan in plans) {
      final point = plan.majorLearningPoint?.trim();
      if (point != null && point.isNotEmpty) {
        description = point;
        break;
      }
    }

    // Real embedded lesson plans label their own objectives entries as
    // syllabus-style competency statements ("General Competence: ...",
    // "Specific Competence 1.1.1.1: ..."), the same real wording the
    // syllabus data elsewhere already stores as Competency rows — everything
    // else (plus each lesson's own real lessonGoal, itself an objective-
    // shaped sentence) becomes a LearningObjective.
    final competencyTexts = <String>{};
    final objectiveTexts = <String>{};
    for (final plan in plans) {
      for (final raw in plan.objectives) {
        final text = raw.trim();
        if (text.isEmpty) continue;
        if (_competenceLabel.hasMatch(text)) {
          competencyTexts.add(text);
        } else {
          objectiveTexts.add(text);
        }
      }
      final goal = plan.lessonGoal?.trim();
      if (goal != null && goal.isNotEmpty) objectiveTexts.add(goal);
    }

    // A sub-topic backed by real content should never end up with both
    // buckets empty — a defensive fallback, not expected in practice since
    // FineTuneCandidateFinder already requires substantial real body text
    // before offering a candidate at all.
    if (competencyTexts.isEmpty && objectiveTexts.isEmpty) {
      for (final plan in plans) {
        objectiveTexts.addAll(plan.objectives.map((o) => o.trim()).where((o) => o.isNotEmpty));
      }
    }

    final competencies = <Competency>[];
    var seq = 1;
    for (final text in competencyTexts.take(6)) {
      competencies.add(Competency(id: nextSyntheticId(), sequenceNumber: seq++, description: text));
    }
    final objectives = <LearningObjective>[];
    seq = 1;
    for (final text in objectiveTexts.take(6)) {
      objectives.add(LearningObjective(id: nextSyntheticId(), sequenceNumber: seq++, description: text));
    }

    return Topic(
      id: nextSyntheticId(),
      sequenceNumber: 0,
      name: subtopicName,
      description: description,
      competencies: competencies,
      objectives: objectives,
    );
  }
}
