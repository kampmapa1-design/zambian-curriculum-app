/// One column of a Scheme of Work document. Templates are data (see
/// [defaultCbcSchemeOfWorkTemplate]/[defaultObcSchemeOfWorkTemplate]), not
/// hardcoded UI — correcting a label or column order means editing this
/// file's defaults, not rebuilding screens. Mirrors the
/// [LessonPlanFieldDef]/[RecordOfWorkColumnDef] pattern used elsewhere.
class SchemeOfWorkColumnDef {
  final String id;
  final String label;

  /// True for columns filled in directly from the syllabus/scheme-of-work
  /// entry (week, topic, sub-topic, competences, activities) — never
  /// editable, since they're the source of truth.
  final bool autoFilled;

  /// True for a column that gets a reasonable auto-generated *starting*
  /// value (e.g. "Expected Standards" derived from the specific
  /// competence) but stays editable, unlike [autoFilled].
  final bool suggested;

  const SchemeOfWorkColumnDef({
    required this.id,
    required this.label,
    this.autoFilled = false,
    this.suggested = false,
  });

  bool get manualEntry => !autoFilled;
}

class SchemeOfWorkTemplate {
  final String id;
  final String name;
  final String source;
  final List<SchemeOfWorkColumnDef> columns;

  const SchemeOfWorkTemplate({
    required this.id,
    required this.name,
    required this.source,
    required this.columns,
  });
}

/// The real CBC (2023) scheme-of-work column layout, reverse-engineered
/// from a real submitted Form 2 English scheme of work (2026) — Week /
/// Stage (which lesson within the week, e.g. "Lesson 3") / Topic / Sub-topic
/// / Key Competences / Specific Competence / Learning Activities (Content)
/// / Expected Standards / Strategies & Methodologies / TL Aids & Materials
/// / References. Only the column structure was kept — any teacher-identifying
/// or vendor-branding details in the source document were left out, per
/// this project's sourcing rules (see feedback-sourcing-rules memory).
///
/// **2026-08-29**: previously only 6-7 of these 11 columns ever got real
/// content — Key Competences, Strategies & Methodologies, and TL Aids &
/// Materials have no corresponding field anywhere in this app's bundled
/// syllabus data, so they rendered blank on every generated scheme
/// regardless of subject (a real, reported bug — schemes "looked like
/// only two columns were filled out"). Now populated with rule-based,
/// always-editable starting suggestions — see
/// scheme_of_work_suggestions.dart for exactly what these are grounded
/// in (well-corroborated general CBC competency themes and standard
/// pedagogy, NOT a transcription of CDC's own document). Learning
/// Activities (Content) also gained a fallback to the topic/sub-topic's
/// description when the syllabus has no learning_objectives for it
/// (true for ~43% of bundled CBC sub-topics) — previously that column
/// went blank in exactly those cases too.
///
/// **2026-08-30**: References was the last column that could still render
/// completely blank — no field for it existed anywhere in the syllabus
/// data model at all (not specific to any one subject). Fixed the same
/// way as [SubTopic.weekNumber]: a real, sourced `references` field
/// (populated where a genuine scheme of work exists — see
/// religious_education_grade10.json for the first real example), with a
/// safe, never-fabricated fallback (just naming the syllabus itself) for
/// everything not yet sourced — see [SchemeOfWorkRowDraft.build].
const defaultCbcSchemeOfWorkTemplate = SchemeOfWorkTemplate(
  id: 'cbc_scheme_of_work_v1',
  name: 'CBC Scheme of Work',
  source: 'Reverse-engineered from a real, teacher-submitted CBC (2023) Form 2 English scheme of work '
      '(2026) — column structure only, no personal or vendor-branding details carried over. Always '
      'used for CBC Form 1-5 schemes, regardless of subject.',
  columns: [
    SchemeOfWorkColumnDef(id: 'week', label: 'Wk', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'stage', label: 'Stage', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'topic', label: 'Topic', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'subTopic', label: 'Sub-topic', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'keyCompetences', label: 'Key Competences', suggested: true),
    SchemeOfWorkColumnDef(id: 'specificCompetence', label: 'Specific Competence', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'learningActivities', label: 'Learning Activities (Content)', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'expectedStandards', label: 'Expected Standards', suggested: true),
    SchemeOfWorkColumnDef(id: 'strategiesMethodologies', label: 'Strategies & Methodologies', suggested: true),
    SchemeOfWorkColumnDef(id: 'tlAidsMaterials', label: 'TL Aids & Materials', suggested: true),
    SchemeOfWorkColumnDef(id: 'references', label: 'References', suggested: true),
  ],
);

/// The real OBC (2013) scheme-of-work column layout, reverse-engineered
/// from a real, genuinely blank Ministry of Education Grade 10-12 Civic
/// Education scheme-of-work template (2026) — a much simpler 6-column
/// layout than CBC's, and structured **one row per week** rather than one
/// row per topic: Week / Topic/Content / Specific Outcomes / Methods /
/// Resources / References. When a week covers more than one topic or
/// sub-topic, they merge into the same Topic/Content and Specific Outcomes
/// cells (see [SchemeOfWorkRowDraft] — OBC rows can hold several entries).
const defaultObcSchemeOfWorkTemplate = SchemeOfWorkTemplate(
  id: 'obc_scheme_of_work_v2',
  name: 'OBC Scheme of Work',
  source: 'Reverse-engineered from a real, blank Ministry of Education Grade 10-12 Civic Education '
      'scheme-of-work template (2026) — no personal names were present in the source (unlike some other '
      'real documents used to build this app, this one was already a genuinely blank template). Always '
      'used for OBC (2013) schemes, regardless of subject.',
  columns: [
    SchemeOfWorkColumnDef(id: 'week', label: 'Week', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'topicContent', label: 'Topic/Content', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'specificOutcomes', label: 'Specific Outcomes', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'methods', label: 'Methods', suggested: true),
    SchemeOfWorkColumnDef(id: 'resources', label: 'Resources', suggested: true),
    SchemeOfWorkColumnDef(id: 'references', label: 'References', suggested: true),
  ],
);

SchemeOfWorkTemplate schemeOfWorkTemplateFor(String curriculumCode) =>
    curriculumCode.toUpperCase().contains('CBC') ? defaultCbcSchemeOfWorkTemplate : defaultObcSchemeOfWorkTemplate;
