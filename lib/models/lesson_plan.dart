enum LessonPlanFieldType { text, multiline }

/// One field in a lesson plan template. Templates are data (see
/// [defaultCdcLessonPlanTemplate]), not hardcoded UI — correcting a label or
/// adding a field means editing this file, not rebuilding screens.
class LessonPlanFieldDef {
  final String id;
  final String label;
  final LessonPlanFieldType type;
  final bool required;

  /// True for fields the app fills in itself from the syllabus/scheme of
  /// work context (Subject, Topic, Sub-topic, competencies) — shown
  /// read-only in the form rather than as something the teacher types.
  final bool autoFilled;
  final String? helpText;

  const LessonPlanFieldDef({
    required this.id,
    required this.label,
    required this.type,
    this.required = false,
    this.autoFilled = false,
    this.helpText,
  });
}

class LessonPlanSectionDef {
  final String id;
  final String title;
  final List<LessonPlanFieldDef> fields;

  const LessonPlanSectionDef({required this.id, required this.title, required this.fields});
}

/// A lesson plan template: header/body field definitions plus the ordered
/// list of "Lesson Progression" stages (Introduction, Lesson Development,
/// ...). Both are configurable so the template can be corrected without a
/// rebuild — see [defaultCdcLessonPlanTemplate] for the shipped default.
class LessonPlanTemplate {
  final String id;
  final String name;

  /// Where this template's field structure was sourced from — shown in the
  /// app so it's traceable, not presented as authoritative with no origin.
  final String source;
  final List<LessonPlanSectionDef> sections;
  final List<String> progressionStages;

  const LessonPlanTemplate({
    required this.id,
    required this.name,
    required this.source,
    required this.sections,
    required this.progressionStages,
  });

  Iterable<LessonPlanFieldDef> get allFields => sections.expand((s) => s.fields);
}

/// The Zambian Ministry of Education / Curriculum Development Centre lesson
/// plan template, as found in a real worked example: "English Language
/// Teaching Module, Form 1, Term 3" (Ministry of Education, Zambia, 2025),
/// Appendix 2: Lesson Plan. Field names and the Lesson Progression stage
/// order are taken from that document; only the specific lesson content in
/// that example (not shipped here) was subject-specific.
const defaultCdcLessonPlanTemplate = LessonPlanTemplate(
  id: 'cdc_lesson_plan_v1',
  name: 'CDC Lesson Plan',
  source: 'Ministry of Education, Zambia — English Language Teaching Module, '
      'Form 1, Term 3 (2025), Appendix 2: Lesson Plan.',
  sections: [
    LessonPlanSectionDef(
      id: 'header',
      title: 'Lesson details',
      fields: [
        LessonPlanFieldDef(id: 'school', label: 'School', type: LessonPlanFieldType.text, required: true),
        LessonPlanFieldDef(
            id: 'teacherName', label: 'Name of Teacher', type: LessonPlanFieldType.text, required: true),
        LessonPlanFieldDef(id: 'date', label: 'Date', type: LessonPlanFieldType.text, required: true),
        LessonPlanFieldDef(id: 'className', label: 'Class', type: LessonPlanFieldType.text, required: true),
        LessonPlanFieldDef(
            id: 'duration', label: 'Duration', type: LessonPlanFieldType.text, helpText: 'e.g. 80 Minutes'),
        LessonPlanFieldDef(
            id: 'time', label: 'Time', type: LessonPlanFieldType.text, helpText: 'e.g. 08:10-09:30'),
        LessonPlanFieldDef(id: 'totalPupils', label: 'Total No. of Pupils', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(id: 'subject', label: 'Subject', type: LessonPlanFieldType.text, autoFilled: true),
        LessonPlanFieldDef(id: 'topic', label: 'Topic', type: LessonPlanFieldType.text, autoFilled: true),
        LessonPlanFieldDef(id: 'subTopic', label: 'Sub-topic', type: LessonPlanFieldType.text, autoFilled: true),
        LessonPlanFieldDef(
          id: 'generalCompetences',
          label: 'General Competence(s)',
          type: LessonPlanFieldType.multiline,
          autoFilled: true,
        ),
        LessonPlanFieldDef(
          id: 'specificCompetences',
          label: 'Specific Competences',
          type: LessonPlanFieldType.multiline,
          autoFilled: true,
        ),
      ],
    ),
    LessonPlanSectionDef(
      id: 'planning',
      title: 'Planning',
      fields: [
        LessonPlanFieldDef(
            id: 'rationale', label: 'Rationale', type: LessonPlanFieldType.multiline, required: true),
        LessonPlanFieldDef(id: 'priorKnowledge', label: 'Prior Knowledge', type: LessonPlanFieldType.multiline),
        LessonPlanFieldDef(id: 'references', label: 'References', type: LessonPlanFieldType.multiline),
        LessonPlanFieldDef(
            id: 'learningEnvironmentNatural', label: 'Learning Environment — Natural', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(
            id: 'learningEnvironmentArtificial',
            label: 'Learning Environment — Artificial',
            type: LessonPlanFieldType.text),
        LessonPlanFieldDef(
            id: 'learningEnvironmentTechnological',
            label: 'Learning Environment — Technological',
            type: LessonPlanFieldType.text),
        LessonPlanFieldDef(
          id: 'tlm',
          label: 'Teaching and Learning Materials/Resources',
          type: LessonPlanFieldType.multiline,
          required: true,
        ),
        LessonPlanFieldDef(
            id: 'expectedStandard', label: 'Expected Standard', type: LessonPlanFieldType.multiline, required: true),
      ],
    ),
    LessonPlanSectionDef(
      id: 'evaluation',
      title: 'After the lesson',
      fields: [
        LessonPlanFieldDef(
          id: 'lessonEvaluation',
          label: 'Lesson Evaluation',
          type: LessonPlanFieldType.multiline,
          helpText: "Filled in after teaching — left blank in the generated document.",
        ),
      ],
    ),
  ],
  progressionStages: ['Introduction', 'Lesson Development', 'Exercise', 'Homework', 'Conclusion'],
);

/// One row of the "Lesson Progression" table.
class LessonProgressionRow {
  final String stage;
  final String teacherRole;
  final String learnersRole;
  final String assessmentCriteria;
  final String durationMinutes;

  const LessonProgressionRow({
    required this.stage,
    this.teacherRole = '',
    this.learnersRole = '',
    this.assessmentCriteria = '',
    this.durationMinutes = '',
  });

  LessonProgressionRow copyWith({
    String? teacherRole,
    String? learnersRole,
    String? assessmentCriteria,
    String? durationMinutes,
  }) =>
      LessonProgressionRow(
        stage: stage,
        teacherRole: teacherRole ?? this.teacherRole,
        learnersRole: learnersRole ?? this.learnersRole,
        assessmentCriteria: assessmentCriteria ?? this.assessmentCriteria,
        durationMinutes: durationMinutes ?? this.durationMinutes,
      );
}

/// A teacher's in-progress or finished lesson plan: values for every
/// template field, plus the Lesson Progression table rows.
class LessonPlanDraft {
  final Map<String, String> values;
  final List<LessonProgressionRow> progression;

  const LessonPlanDraft({this.values = const {}, this.progression = const []});

  String value(String fieldId) => values[fieldId] ?? '';

  LessonPlanDraft withValue(String fieldId, String value) =>
      LessonPlanDraft(values: {...values, fieldId: value}, progression: progression);

  LessonPlanDraft withProgressionRow(int index, LessonProgressionRow row) {
    final updated = [...progression];
    updated[index] = row;
    return LessonPlanDraft(values: values, progression: updated);
  }

  factory LessonPlanDraft.empty(LessonPlanTemplate template) => LessonPlanDraft(
        values: const {},
        progression: [for (final stage in template.progressionStages) LessonProgressionRow(stage: stage)],
      );
}
