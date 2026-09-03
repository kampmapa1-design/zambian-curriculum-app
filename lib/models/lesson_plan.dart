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

  /// True for fields meant to be handwritten onto the printed document
  /// after the lesson (e.g. Teacher's/Learners' Evaluation) — always
  /// printed with a few ruled blank lines even when empty, rather than
  /// being omitted the way an unfilled optional field normally is. See
  /// [LessonPlanDocumentService].
  final bool blankSpaceOnPrint;
  final String? helpText;

  const LessonPlanFieldDef({
    required this.id,
    required this.label,
    required this.type,
    this.required = false,
    this.autoFilled = false,
    this.blankSpaceOnPrint = false,
    this.helpText,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'type': type.name,
        'required': required,
        'autoFilled': autoFilled,
        'blankSpaceOnPrint': blankSpaceOnPrint,
        'helpText': helpText,
      };

  factory LessonPlanFieldDef.fromJson(Map<String, dynamic> json) => LessonPlanFieldDef(
        id: json['id'] as String,
        label: json['label'] as String,
        type: LessonPlanFieldType.values.byName(json['type'] as String),
        required: json['required'] as bool? ?? false,
        autoFilled: json['autoFilled'] as bool? ?? false,
        blankSpaceOnPrint: json['blankSpaceOnPrint'] as bool? ?? false,
        helpText: json['helpText'] as String?,
      );
}

class LessonPlanSectionDef {
  final String id;
  final String title;
  final List<LessonPlanFieldDef> fields;

  const LessonPlanSectionDef({required this.id, required this.title, required this.fields});

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'fields': [for (final f in fields) f.toJson()],
      };

  factory LessonPlanSectionDef.fromJson(Map<String, dynamic> json) => LessonPlanSectionDef(
        id: json['id'] as String,
        title: json['title'] as String,
        fields: [
          for (final f in (json['fields'] as List).cast<Map<String, dynamic>>()) LessonPlanFieldDef.fromJson(f)
        ],
      );
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'source': source,
        'sections': [for (final s in sections) s.toJson()],
        'progressionStages': progressionStages,
      };

  factory LessonPlanTemplate.fromJson(Map<String, dynamic> json) => LessonPlanTemplate(
        id: json['id'] as String,
        name: json['name'] as String,
        source: json['source'] as String,
        sections: [
          for (final s in (json['sections'] as List).cast<Map<String, dynamic>>())
            LessonPlanSectionDef.fromJson(s)
        ],
        progressionStages: (json['progressionStages'] as List).cast<String>(),
      );
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
          id: 'teacherEvaluation',
          label: "Teacher's Evaluation",
          type: LessonPlanFieldType.multiline,
          required: true,
          blankSpaceOnPrint: true,
          helpText: 'Filled in after teaching — printed with blank ruled lines for a handwritten note.',
        ),
        LessonPlanFieldDef(
          id: 'learnerEvaluation',
          label: "Learners' Evaluation",
          type: LessonPlanFieldType.multiline,
          required: true,
          blankSpaceOnPrint: true,
          helpText: 'Filled in after teaching — printed with blank ruled lines for a handwritten note.',
        ),
      ],
    ),
  ],
  progressionStages: ['Introduction', 'Lesson Development', 'Exercise', 'Homework', 'Conclusion'],
);

/// The 2023 Competency-Based Curriculum lesson plan template, sourced from
/// real Form 1 History/Civic Education/Mathematics CBC lesson plan samples
/// (2026) provided by the user. Structurally distinct from
/// [defaultCdcLessonPlanTemplate] (the 2013 OBC template): a narrower "Major
/// learning point/Activity" per lesson (a subtopic typically spans several
/// lessons, one per learning objective), an explicit Lesson Goal and Prior
/// Knowledge chaining lessons together, and a single Lesson Evaluation field
/// rather than a split Teacher's/Learners' Evaluation — the real CBC samples
/// consistently use one field, so this template follows that rather than
/// the OBC form's structure.
const defaultCbcLessonPlanTemplate = LessonPlanTemplate(
  id: 'cbc_lesson_plan_v1',
  name: 'CBC Lesson Plan',
  source: 'Real Form 1 CBC lesson plan samples (History, Civic Education, Mathematics), provided by the '
      'user (2026), cross-referenced against the 2023 Competency-Based Curriculum syllabus structure.',
  sections: [
    LessonPlanSectionDef(
      id: 'header',
      title: 'Lesson details',
      fields: [
        LessonPlanFieldDef(id: 'teacherName', label: 'Name of Teacher', type: LessonPlanFieldType.text),
        // Added 2026-09-03 — real gap: this template had no School field at
        // all (unlike defaultCdcLessonPlanTemplate's, which does), so a
        // teacher using a CBC subject had nowhere to enter it.
        LessonPlanFieldDef(id: 'school', label: 'School', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(id: 'term', label: 'Term', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(id: 'date', label: 'Date', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(id: 'time', label: 'Time', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(
            id: 'duration', label: 'Duration', type: LessonPlanFieldType.text, helpText: 'e.g. 40 minutes'),
        LessonPlanFieldDef(id: 'enrolmentBoys', label: 'Enrolment — Boys', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(id: 'enrolmentGirls', label: 'Enrolment — Girls', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(id: 'subject', label: 'Subject', type: LessonPlanFieldType.text, autoFilled: true),
        LessonPlanFieldDef(id: 'className', label: 'Form', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(id: 'attendanceBoys', label: 'Attendance — Boys', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(id: 'attendanceGirls', label: 'Attendance — Girls', type: LessonPlanFieldType.text),
        LessonPlanFieldDef(id: 'topic', label: 'Topic', type: LessonPlanFieldType.text, autoFilled: true),
        LessonPlanFieldDef(id: 'subTopic', label: 'Sub-Topic', type: LessonPlanFieldType.text, autoFilled: true),
        LessonPlanFieldDef(
          id: 'generalCompetences',
          label: 'General Competences',
          type: LessonPlanFieldType.multiline,
          autoFilled: true,
        ),
        LessonPlanFieldDef(
          id: 'specificCompetences',
          label: 'Specific Competences',
          type: LessonPlanFieldType.multiline,
          autoFilled: true,
        ),
        LessonPlanFieldDef(
          id: 'majorLearningPoint',
          label: 'Major Learning Point/Activity',
          type: LessonPlanFieldType.multiline,
          required: true,
          autoFilled: true,
          helpText: "This lesson's specific slice of the sub-topic — a sub-topic usually spans several "
              'lessons, one per learning objective.',
        ),
        LessonPlanFieldDef(
          id: 'lessonGoal',
          label: 'Lesson Goal',
          type: LessonPlanFieldType.multiline,
          required: true,
          helpText: "By the end of the lesson, learners will be able to... — refine the auto-filled draft "
              'to fit this specific class.',
        ),
      ],
    ),
    LessonPlanSectionDef(
      id: 'planning',
      title: 'Planning',
      fields: [
        LessonPlanFieldDef(id: 'rationale', label: 'Rationale', type: LessonPlanFieldType.multiline, required: true),
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
          label: 'Teaching and Learning Resources/Materials',
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
          required: true,
          blankSpaceOnPrint: true,
          helpText: 'Filled in after teaching — printed with blank ruled lines for a handwritten note.',
        ),
      ],
    ),
  ],
  progressionStages: ['Introduction', 'Development', 'Exercise', 'Homework', 'Conclusion'],
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

  Map<String, dynamic> toJson() => {
        'stage': stage,
        'teacherRole': teacherRole,
        'learnersRole': learnersRole,
        'assessmentCriteria': assessmentCriteria,
        'durationMinutes': durationMinutes,
      };

  factory LessonProgressionRow.fromJson(Map<String, dynamic> json) => LessonProgressionRow(
        stage: json['stage'] as String,
        teacherRole: json['teacherRole'] as String? ?? '',
        learnersRole: json['learnersRole'] as String? ?? '',
        assessmentCriteria: json['assessmentCriteria'] as String? ?? '',
        durationMinutes: json['durationMinutes'] as String? ?? '',
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

  Map<String, dynamic> toJson() => {
        'values': values,
        'progression': [for (final r in progression) r.toJson()],
      };

  factory LessonPlanDraft.fromJson(Map<String, dynamic> json) => LessonPlanDraft(
        values: (json['values'] as Map).cast<String, String>(),
        progression: [
          for (final r in (json['progression'] as List).cast<Map<String, dynamic>>())
            LessonProgressionRow.fromJson(r)
        ],
      );
}
