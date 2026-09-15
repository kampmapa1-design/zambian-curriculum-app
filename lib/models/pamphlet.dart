/// A bundled reference pamphlet/notes document — real subject content
/// (e.g. a CDC-style topic pamphlet or question bank) that isn't a scheme
/// of work in its own right, so it doesn't belong in `assets/syllabi/`,
/// but is still real, useful grounding for AI generation. Deliberately
/// never surfaced in any picker/browse UI (2026-09-15, per explicit
/// request) — see [PamphletRepository] and [SubjectContentIndex] for how
/// it's actually consumed, always as background context, never as
/// something a teacher navigates to directly.
class Pamphlet {
  const Pamphlet({
    required this.subjectName,
    required this.curriculumCode,
    required this.gradeLevels,
    required this.title,
    required this.fullText,
    this.source,
  });

  final String subjectName;

  /// 'CBC_2023', 'OBC_2013', or null when the pamphlet's own content
  /// doesn't name a specific curriculum edition (rare, but real — some
  /// topic pamphlets are written generically enough to apply either way).
  final String? curriculumCode;

  final List<int> gradeLevels;
  final String title;
  final String fullText;

  /// Provenance/sanitization note, same convention as every bundled
  /// syllabus file's own `_source` field — never shown in the app itself.
  final String? source;

  factory Pamphlet.fromJson(Map<String, dynamic> json) => Pamphlet(
        subjectName: json['subjectName'] as String,
        curriculumCode: json['curriculumCode'] as String?,
        gradeLevels: (json['gradeLevels'] as List).cast<int>(),
        title: json['title'] as String,
        fullText: json['fullText'] as String,
        source: json['_source'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'subjectName': subjectName,
        if (curriculumCode != null) 'curriculumCode': curriculumCode,
        'gradeLevels': gradeLevels,
        'title': title,
        'fullText': fullText,
        if (source != null) '_source': source,
      };
}
