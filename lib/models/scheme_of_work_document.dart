import 'scheme_of_work.dart';

/// Once-per-document header fields for the CDC "Scheme of Work" template
/// (Ministry of Education / Name of School / Name of Teacher / Level /
/// Subject / Year), plus the "Curriculum Philosophy and Goals" block that
/// appears once at the top of real CDC scheme-of-work documents rather than
/// per week.
class SchemeOfWorkHeader {
  final String schoolName;
  final String teacherName;
  final String year;
  final String curriculumPhilosophyAndGoals;

  const SchemeOfWorkHeader({
    this.schoolName = '',
    this.teacherName = '',
    this.year = '',
    this.curriculumPhilosophyAndGoals = '',
  });

  SchemeOfWorkHeader copyWith({
    String? schoolName,
    String? teacherName,
    String? year,
    String? curriculumPhilosophyAndGoals,
  }) =>
      SchemeOfWorkHeader(
        schoolName: schoolName ?? this.schoolName,
        teacherName: teacherName ?? this.teacherName,
        year: year ?? this.year,
        curriculumPhilosophyAndGoals: curriculumPhilosophyAndGoals ?? this.curriculumPhilosophyAndGoals,
      );
}

/// One row of the CDC scheme-of-work table for one [SchemeOfWorkEntry].
///
/// Week, Topic/Sub-topic, Specific Competences, and Learning Activities come
/// straight from syllabus data already on-device — never editable here,
/// since they're the source of truth. The remaining CDC columns
/// (Prescribed Competences, Content/Concept, Expected Standard,
/// Strategies/Methods, Assessments, Material/Resources, References) aren't
/// part of the app's syllabus data model, so they start blank (or, for
/// Expected Standard, pre-filled from the topic/sub-topic description when
/// one is present) and are filled in by the teacher.
class SchemeOfWorkRowDraft {
  final SchemeOfWorkEntry entry;
  final String prescribedCompetences;
  final String contentConcept;
  final String expectedStandard;
  final String strategiesMethods;
  final String assessments;
  final String materialResources;
  final String references;

  const SchemeOfWorkRowDraft({
    required this.entry,
    this.prescribedCompetences = '',
    this.contentConcept = '',
    this.expectedStandard = '',
    this.strategiesMethods = '',
    this.assessments = '',
    this.materialResources = '',
    this.references = '',
  });

  factory SchemeOfWorkRowDraft.fromEntry(SchemeOfWorkEntry entry) => SchemeOfWorkRowDraft(
        entry: entry,
        expectedStandard: (entry.subTopic?.description ?? entry.topic.description) ?? '',
      );

  SchemeOfWorkRowDraft copyWith({
    String? prescribedCompetences,
    String? contentConcept,
    String? expectedStandard,
    String? strategiesMethods,
    String? assessments,
    String? materialResources,
    String? references,
  }) =>
      SchemeOfWorkRowDraft(
        entry: entry,
        prescribedCompetences: prescribedCompetences ?? this.prescribedCompetences,
        contentConcept: contentConcept ?? this.contentConcept,
        expectedStandard: expectedStandard ?? this.expectedStandard,
        strategiesMethods: strategiesMethods ?? this.strategiesMethods,
        assessments: assessments ?? this.assessments,
        materialResources: materialResources ?? this.materialResources,
        references: references ?? this.references,
      );
}

/// The full editable draft for one scheme-of-work document: one header plus
/// one row per generated [SchemeOfWorkEntry].
class SchemeOfWorkDocumentDraft {
  final SchemeOfWorkHeader header;
  final List<SchemeOfWorkRowDraft> rows;

  const SchemeOfWorkDocumentDraft({required this.header, required this.rows});

  factory SchemeOfWorkDocumentDraft.fromEntries(List<SchemeOfWorkEntry> entries) => SchemeOfWorkDocumentDraft(
        header: const SchemeOfWorkHeader(),
        rows: [for (final entry in entries) SchemeOfWorkRowDraft.fromEntry(entry)],
      );

  SchemeOfWorkDocumentDraft withHeader(SchemeOfWorkHeader header) =>
      SchemeOfWorkDocumentDraft(header: header, rows: rows);

  SchemeOfWorkDocumentDraft withRow(int index, SchemeOfWorkRowDraft row) {
    final updated = [...rows];
    updated[index] = row;
    return SchemeOfWorkDocumentDraft(header: header, rows: updated);
  }
}
