import '../models/lesson_plan.dart';
import '../models/scheme_of_work.dart';

/// Fills every "Lesson Progression" row with default, syllabus-derived
/// content for [entry]. Most topics have no curated Guided Planning
/// activity bank (see GuidedPlanningEngine, which only covers topics with a
/// hand-authored assets/activity_banks/*.json) — this is what makes a
/// freshly generated lesson plan non-empty for every other topic.
///
/// Stage names are recognized by keyword ("introduction", "development",
/// "exercise", "homework", "conclusion" — matching [LessonStage] and the
/// bundled CDC template's progressionStages); any other/custom stage name
/// (e.g. from a teacher-uploaded template) is left blank rather than
/// guessed at, since its intent isn't known.
/// [subjectContentExcerpt] is real content pulled from a downloaded
/// Teaching Module in the on-device Subject Content Database (see
/// SubjectContentRepository.findRelevantExcerpt) — woven into the
/// Development stage, where a teacher most needs real explanatory
/// material rather than just a list of competencies to cover. Entirely
/// optional: omit it (or pass null) and this behaves exactly as it
/// always has.
List<LessonProgressionRow> generateDefaultProgression(
  List<String> progressionStages,
  SchemeOfWorkEntry entry, {
  String? subjectContentExcerpt,
}) {
  final competencies = entry.competencies.map((c) => c.description).toList();
  final objectives = entry.objectives.map((o) => o.description).toList();
  final topicLabel = entry.title;

  return [
    for (final stage in progressionStages)
      _rowFor(
        stage: stage,
        topicLabel: topicLabel,
        competencies: competencies,
        objectives: objectives,
        subjectContentExcerpt: subjectContentExcerpt,
      ),
  ];
}

String _bulletList(List<String> lines) => lines.map((l) => '•  $l').join('\n');

LessonProgressionRow _rowFor({
  required String stage,
  required String topicLabel,
  required List<String> competencies,
  required List<String> objectives,
  String? subjectContentExcerpt,
}) {
  final name = stage.toLowerCase();

  if (name.contains('introduction')) {
    final headline = objectives.isNotEmpty ? objectives : competencies;
    return LessonProgressionRow(
      stage: stage,
      teacherRole: 'Introduce "$topicLabel". Review related prior knowledge with the class, then state '
          'what learners will be able to do by the end of the lesson:'
          '${headline.isEmpty ? '' : '\n${_bulletList(headline)}'}',
      learnersRole: "Respond to the teacher's review questions and note the lesson's objectives.",
      assessmentCriteria: 'Learners can restate the lesson objectives in their own words.',
    );
  }

  if (name.contains('development')) {
    return LessonProgressionRow(
      stage: stage,
      teacherRole: 'Guide learners through activities covering each competency for this topic:'
          '${competencies.isEmpty ? '' : '\n${_bulletList(competencies)}'}'
          '${subjectContentExcerpt == null || subjectContentExcerpt.isEmpty ? '' : '\n\nBackground (from your downloaded Teaching Module):\n$subjectContentExcerpt'}',
      learnersRole: 'Participate in activities (discussion, practice, demonstration) to develop each '
          'competency above.',
      assessmentCriteria: 'Observe learners demonstrating each competency during the activity.',
    );
  }

  if (name.contains('exercise')) {
    return LessonProgressionRow(
      stage: stage,
      teacherRole: 'Set a short written or oral exercise assessing the competencies covered today.',
      learnersRole: 'Complete the exercise individually or in pairs.',
      assessmentCriteria: competencies.isEmpty
          ? 'Learners complete the exercise correctly.'
          : 'Learners correctly:\n${_bulletList(competencies)}',
    );
  }

  if (name.contains('homework')) {
    return LessonProgressionRow(
      stage: stage,
      teacherRole: "Assign follow-up practice on today's competencies for learners to complete before "
          'the next lesson.',
      learnersRole: 'Complete the homework and bring it for review next lesson.',
    );
  }

  if (name.contains('conclusion')) {
    return LessonProgressionRow(
      stage: stage,
      teacherRole: "Summarise the lesson's key points and clear up any misconceptions.",
      learnersRole: 'Summarise, in their own words, what was learnt.',
      assessmentCriteria: "Learners can summarise the lesson's main points.",
    );
  }

  return LessonProgressionRow(stage: stage);
}
