/// One candidate learning activity for a sub-topic, tagged for the guided
/// Q&A engine (Stage 5) to filter/reorder/lock against. See
/// assets/activity_banks/*.json for real, sourced examples — the
/// `requiresSpecialAids`/`styleTags`/`foundational` tags are this app's own
/// curatorial additions on top of real CDC activity text, not official CDC
/// designations themselves.
class ActivityCandidate {
  final String id;
  final String description;
  final String materials;
  final List<String> competencyTags;
  final bool requiresSpecialAids;
  final Set<String> styleTags;
  final bool foundational;

  const ActivityCandidate({
    required this.id,
    required this.description,
    required this.materials,
    required this.competencyTags,
    required this.requiresSpecialAids,
    required this.styleTags,
    required this.foundational,
  });

  factory ActivityCandidate.fromJson(Map<String, dynamic> json) => ActivityCandidate(
        id: json['id'] as String,
        description: json['description'] as String,
        materials: json['materials'] as String? ?? '',
        competencyTags: (json['competency_tags'] as List? ?? const []).cast<String>(),
        requiresSpecialAids: json['requires_special_aids'] as bool? ?? false,
        styleTags: {...(json['style_tags'] as List? ?? const []).cast<String>()},
        foundational: json['foundational'] as bool? ?? false,
      );
}

/// The activity bank for one sub-topic: the real competency it must cover,
/// plus every candidate activity the guided Q&A engine can choose between.
class ActivityBank {
  final String curriculumCode;
  final String subjectCode;
  final String subTopicName;
  final List<String> competencyTags;
  final List<ActivityCandidate> activities;
  final String? source;

  const ActivityBank({
    required this.curriculumCode,
    required this.subjectCode,
    required this.subTopicName,
    required this.competencyTags,
    required this.activities,
    this.source,
  });

  factory ActivityBank.fromJson(Map<String, dynamic> json) => ActivityBank(
        curriculumCode: json['curriculum_code'] as String,
        subjectCode: json['subject_code'] as String,
        subTopicName: json['sub_topic_name'] as String,
        competencyTags: (json['competency_tags'] as List? ?? const []).cast<String>(),
        activities: [
          for (final a in (json['activities'] as List).cast<Map<String, dynamic>>())
            ActivityCandidate.fromJson(a)
        ],
        source: json['_source'] as String?,
      );
}
