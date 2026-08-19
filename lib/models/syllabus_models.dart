/// A curriculum system, e.g. the 2023 Competency-Based Curriculum or the
/// 2013 Outcome-Based Curriculum. Every subject and grade belongs to exactly
/// one curriculum, so the two can coexist in local storage without their
/// data ever mixing.
class Curriculum {
  final int id;
  final String code;
  final String name;
  final String? description;

  const Curriculum({
    required this.id,
    required this.code,
    required this.name,
    this.description,
  });

  factory Curriculum.fromMap(Map<String, Object?> map) => Curriculum(
        id: map['id'] as int,
        code: map['code'] as String,
        name: map['name'] as String,
        description: map['description'] as String?,
      );
}

class Subject {
  final int id;
  final int curriculumId;
  final String name;
  final String code;
  final String? description;

  const Subject({
    required this.id,
    required this.curriculumId,
    required this.name,
    required this.code,
    this.description,
  });

  factory Subject.fromMap(Map<String, Object?> map) => Subject(
        id: map['id'] as int,
        curriculumId: map['curriculum_id'] as int,
        name: map['name'] as String,
        code: map['code'] as String,
        description: map['description'] as String?,
      );
}

class Grade {
  final int id;
  final int curriculumId;
  final String name;
  final String code;

  /// Ordering within the curriculum (e.g. 1-12 for CBC grades, 1-6 for a
  /// secondary "Form" system). Stored as `sequence_number` in the database —
  /// kept as `level` here since most call sites predate multi-curriculum
  /// support and "level" reads naturally for both grades and forms.
  final int level;
  final String? phase;

  const Grade({
    required this.id,
    required this.curriculumId,
    required this.name,
    required this.code,
    required this.level,
    this.phase,
  });

  factory Grade.fromMap(Map<String, Object?> map) => Grade(
        id: map['id'] as int,
        curriculumId: map['curriculum_id'] as int,
        name: map['name'] as String,
        code: map['code'] as String,
        level: map['sequence_number'] as int,
        phase: map['phase'] as String?,
      );
}

class LearningObjective {
  final int id;
  final int sequenceNumber;
  final String description;

  const LearningObjective({
    required this.id,
    required this.sequenceNumber,
    required this.description,
  });

  factory LearningObjective.fromMap(Map<String, Object?> map) => LearningObjective(
        id: map['id'] as int,
        sequenceNumber: map['sequence_number'] as int,
        description: map['description'] as String,
      );
}

class Competency {
  final int id;
  final int sequenceNumber;
  final String description;
  final String? category;

  const Competency({
    required this.id,
    required this.sequenceNumber,
    required this.description,
    this.category,
  });

  factory Competency.fromMap(Map<String, Object?> map) => Competency(
        id: map['id'] as int,
        sequenceNumber: map['sequence_number'] as int,
        description: map['description'] as String,
        category: map['category'] as String?,
      );
}

class SubTopic {
  final int id;
  final int sequenceNumber;
  final String name;
  final String? description;
  final List<LearningObjective> objectives;
  final List<Competency> competencies;

  const SubTopic({
    required this.id,
    required this.sequenceNumber,
    required this.name,
    this.description,
    this.objectives = const [],
    this.competencies = const [],
  });
}

class Topic {
  final int id;
  final int sequenceNumber;
  final String name;
  final String? description;
  final List<SubTopic> subTopics;
  final List<LearningObjective> objectives;
  final List<Competency> competencies;

  const Topic({
    required this.id,
    required this.sequenceNumber,
    required this.name,
    this.description,
    this.subTopics = const [],
    this.objectives = const [],
    this.competencies = const [],
  });
}

class Term {
  final int id;
  final int sequenceNumber;
  final String name;
  final List<Topic> topics;

  const Term({
    required this.id,
    required this.sequenceNumber,
    required this.name,
    this.topics = const [],
  });
}

class SyllabusTemplate {
  final Curriculum curriculum;
  final Subject subject;
  final Grade grade;
  final List<Term> terms;

  const SyllabusTemplate({
    required this.curriculum,
    required this.subject,
    required this.grade,
    required this.terms,
  });
}

/// One entry in assets/syllabi/manifest.json — lets the selector screen list
/// bundled curriculum/subject/grade combinations without parsing every
/// template file.
class TemplateManifestEntry {
  final String curriculumCode;
  final String curriculumName;
  final String subjectCode;
  final String subjectName;
  final int gradeLevel;
  final String gradeName;
  final String file;

  const TemplateManifestEntry({
    required this.curriculumCode,
    required this.curriculumName,
    required this.subjectCode,
    required this.subjectName,
    required this.gradeLevel,
    required this.gradeName,
    required this.file,
  });

  factory TemplateManifestEntry.fromJson(Map<String, dynamic> json) => TemplateManifestEntry(
        curriculumCode: json['curriculum_code'] as String,
        curriculumName: json['curriculum_name'] as String,
        subjectCode: json['subject_code'] as String,
        subjectName: json['subject_name'] as String,
        gradeLevel: json['grade_level'] as int,
        gradeName: json['grade_name'] as String,
        file: json['file'] as String,
      );
}
