import '../models/lesson_plan.dart';
import '../models/scheme_of_work.dart';
import 'lesson_teaching_points.dart';
import 'text_excerpt_matching.dart';

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
///
/// Teacher's Role kept deliberately short (2026-09-10, per explicit
/// request: "the new lesson plan has unnecessarily long details in the
/// 'Teacher's Role' column... summarize... so the whole lesson plan does
/// not exceed 2 pages" — a real consequence of every stage now generating
/// in one document instead of just one picked stage, see
/// generate_lesson_plan_flow.dart's own 2026-09-10 doc comment). The
/// Introduction and Development stages used to repeat, in full, content
/// that's already printed elsewhere in the same document — every
/// objective again (already in Rationale, see
/// LessonPlanScreen._rebuildForActiveTemplate's own syllabus auto-fill),
/// every competency again (already in Specific Competences, same place)
/// — so those repeats are dropped
/// rather than merely shortened: no real information is lost, since it's
/// still fully visible in its own dedicated field, just not duplicated
/// here too. The one real piece of content that has nowhere else to live
/// — Development's own [subjectContentExcerpt] background material — is
/// capped much shorter ([_teacherRoleExcerptWordCap] words) rather than
/// dropped outright, since summarizing it (not removing it) is what was
/// actually asked for.
/// How much of [SchemeOfWorkEntry]-independent `subjectContentExcerpt`
/// background material Development's own Teacher's Role cell keeps — see
/// this file's own doc comment on why this is capped rather than shown
/// in full (it can otherwise run up to 350 words on its own — see
/// SubjectContentRepository.findRelevantExcerpt's own default cap).
const _teacherRoleExcerptWordCap = 60;

/// The default text for the OBC layouts' "10. Homework / Extension
/// Activity" section — those templates have no Homework stage row (section
/// 10 replaces it), so this is where what the stage row would have said goes.
const defaultObcHomeworkText =
    "Assign follow-up practice on today's lesson for learners to complete before the next lesson.";

/// [contentMode] (2026-09-26, OBC template work) decides what happens to the
/// lesson's syllabus content — see [LessonProgressionContentMode]:
/// - foldedIntoTeacherRole (default — every pre-existing template): exactly
///   the behaviour described above, unchanged.
/// - ownColumn: the content goes into each row's own `content` (learning
///   points as bullets, background excerpt), and Teacher's Role no longer
///   carries the excerpt.
/// - omitted: no content anywhere — NOT folded into Teacher's/Learners'
///   Role either (explicit instruction), so the Development excerpt is
///   dropped rather than relocated.
List<LessonProgressionRow> generateDefaultProgression(
  List<String> progressionStages,
  SchemeOfWorkEntry entry, {
  String? subjectContentExcerpt,
  LessonProgressionContentMode contentMode = LessonProgressionContentMode.foldedIntoTeacherRole,
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
        contentMode: contentMode,
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
  required LessonProgressionContentMode contentMode,
}) {
  final name = stage.toLowerCase();
  final ownColumn = contentMode == LessonProgressionContentMode.ownColumn;
  final hasExcerpt = subjectContentExcerpt != null && subjectContentExcerpt.isNotEmpty;

  if (name.contains('introduction')) {
    return LessonProgressionRow(
      stage: stage,
      content: ownColumn ? "Topic: $topicLabel\nLink to learners' prior knowledge" : '',
      // The objectives themselves are NOT repeated here — they're already
      // printed in full in Rationale (see this file's own doc comment).
      teacherRole: 'Introduce "$topicLabel". Review related prior knowledge with the class, then state the '
          "lesson's objectives (see Rationale above).",
      learnersRole: "Respond to the teacher's review questions and note the lesson's objectives.",
      assessmentCriteria: 'Learners can restate the lesson objectives in their own words.',
    );
  }

  if (name.contains('development')) {
    // The competencies themselves are NOT repeated here — they're already
    // printed in full in Specific Competences (see this file's own doc
    // comment). subjectContentExcerpt has nowhere else to live, so it's
    // summarized (capped much shorter) rather than dropped outright.
    final foldedExcerpt = contentMode == LessonProgressionContentMode.foldedIntoTeacherRole && hasExcerpt
        ? '\n\nBackground: ${capExcerptWords(subjectContentExcerpt, _teacherRoleExcerptWordCap)}'
        : '';
    final learningPoints = objectives.isNotEmpty ? objectives : competencies;
    return LessonProgressionRow(
      stage: stage,
      // Up to six real teaching points (2026-09-26, per explicit request):
      // taken from the same on-device lesson material the companion Lesson
      // Notes are grounded in, topped up with the syllabus's own outcomes
      // when that material is thin or absent — never invented, so a topic
      // with neither simply has fewer.
      content: ownColumn
          ? bulletLines(ensureMinimumPoints(
              topUpPoints(
                teachingPointsFromText(
                  subjectContentExcerpt,
                  relevantTo: keywordsOf('$topicLabel ${learningPoints.join(' ')}'),
                ),
                learningPoints,
              ),
              outcomes: learningPoints,
              topicLabel: topicLabel,
            ))
          : '',
      teacherRole: ownColumn
          ? 'Guide learners through activities covering each learning point in the Content column.'
          : 'Guide learners through activities covering each competency for this topic (see Specific '
              'Competences above).$foldedExcerpt',
      learnersRole: 'Participate in activities (discussion, practice, demonstration) to develop each '
          'competency above.',
      assessmentCriteria: 'Observe learners demonstrating each competency during the activity.',
    );
  }

  if (name.contains('exercise')) {
    return LessonProgressionRow(
      stage: stage,
      content: ownColumn ? 'Short exercise on the key learning points.' : '',
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
      content: ownColumn ? 'Summary of the key learning points.' : '',
      teacherRole: "Summarise the lesson's key points and clear up any misconceptions.",
      learnersRole: 'Summarise, in their own words, what was learnt.',
      assessmentCriteria: "Learners can summarise the lesson's main points.",
    );
  }

  return LessonProgressionRow(stage: stage);
}
