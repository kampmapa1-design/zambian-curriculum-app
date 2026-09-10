/// "Concise Marking" exam rubric (Scan Marker, 2026-09-10, per explicit
/// request) — the section/instruction structure of an examination as it is
/// printed on the FIRST script's own cover / instructions page. Extracted
/// once, by `gradeMarkingScriptConcise`, from the first script of a
/// cohort, then reused verbatim for every following script in that same
/// session ("always get the marking instruction from the first cover page
/// of any exam... the questions you will be marking shall be the same").
///
/// Purely a record of what the paper itself says — never invented. The
/// deterministic scoring math lives in [ConciseScoreCalculator], not here.
class RubricSection {
  /// Verbatim section label, e.g. "Section A", "Section C".
  final String name;

  /// How many questions the candidate is REQUIRED to answer from this
  /// section (e.g. "answer any ONE question" -> 1). Null when the paper
  /// does not restrict it — answer everything in the section.
  final int? questionsToAnswer;

  /// Marks this section is worth on the paper, exactly as allocated. Null
  /// when the paper states no explicit section total.
  final double? marksAllocated;

  const RubricSection({
    required this.name,
    this.questionsToAnswer,
    this.marksAllocated,
  });

  factory RubricSection.fromJson(Map<String, dynamic> json) => RubricSection(
        name: (json['name'] as String?)?.trim() ?? '',
        questionsToAnswer: (json['questionsToAnswer'] as num?)?.toInt(),
        marksAllocated: (json['marksAllocated'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        if (questionsToAnswer != null) 'questionsToAnswer': questionsToAnswer,
        if (marksAllocated != null) 'marksAllocated': marksAllocated,
      };
}

class MarkingRubric {
  final List<RubricSection> sections;

  /// The paper's own stated grand total (e.g. "Total: 100 marks"). Null
  /// when the paper states none.
  final double? paperTotalMarks;

  /// A short plain-language digest of the cover-page instructions the
  /// marking actually depended on — shown to the teacher, never acted on
  /// blindly.
  final String instructionsSummary;

  const MarkingRubric({
    required this.sections,
    this.paperTotalMarks,
    this.instructionsSummary = '',
  });

  bool get isEmpty => sections.isEmpty && paperTotalMarks == null && instructionsSummary.trim().isEmpty;

  /// The required questions-to-answer for a given section name (case- and
  /// whitespace-insensitive match), or null when the section isn't in the
  /// rubric or doesn't restrict the count.
  int? requiredCountFor(String sectionName) {
    final target = sectionName.trim().toLowerCase();
    for (final s in sections) {
      if (s.name.trim().toLowerCase() == target) return s.questionsToAnswer;
    }
    return null;
  }

  double? allocatedMarksFor(String sectionName) {
    final target = sectionName.trim().toLowerCase();
    for (final s in sections) {
      if (s.name.trim().toLowerCase() == target) return s.marksAllocated;
    }
    return null;
  }

  factory MarkingRubric.fromJson(Map<String, dynamic> json) => MarkingRubric(
        sections: (json['sections'] as List?)
                ?.whereType<Map>()
                .map((m) => RubricSection.fromJson(m.cast<String, dynamic>()))
                .where((s) => s.name.isNotEmpty)
                .toList() ??
            const [],
        paperTotalMarks: (json['paperTotalMarks'] as num?)?.toDouble(),
        instructionsSummary: (json['instructionsSummary'] as String?)?.trim() ?? '',
      );

  Map<String, dynamic> toJson() => {
        'sections': [for (final s in sections) s.toJson()],
        if (paperTotalMarks != null) 'paperTotalMarks': paperTotalMarks,
        'instructionsSummary': instructionsSummary,
      };
}
