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
    SchemeOfWorkColumnDef(id: 'keyCompetences', label: 'Key Competences'),
    SchemeOfWorkColumnDef(id: 'specificCompetence', label: 'Specific Competence', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'learningActivities', label: 'Learning Activities (Content)', autoFilled: true),
    SchemeOfWorkColumnDef(id: 'expectedStandards', label: 'Expected Standards', suggested: true),
    SchemeOfWorkColumnDef(id: 'strategiesMethodologies', label: 'Strategies & Methodologies'),
    SchemeOfWorkColumnDef(id: 'tlAidsMaterials', label: 'TL Aids & Materials'),
    SchemeOfWorkColumnDef(id: 'references', label: 'References'),
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
    SchemeOfWorkColumnDef(id: 'methods', label: 'Methods'),
    SchemeOfWorkColumnDef(id: 'resources', label: 'Resources'),
    SchemeOfWorkColumnDef(id: 'references', label: 'References'),
  ],
);

SchemeOfWorkTemplate schemeOfWorkTemplateFor(String curriculumCode) =>
    curriculumCode.toUpperCase().contains('CBC') ? defaultCbcSchemeOfWorkTemplate : defaultObcSchemeOfWorkTemplate;
