import 'marking_scheme.dart';

/// One node in a marking scheme's structural tree — a Section's top-level
/// Question (Arabic numeral, e.g. "2"), a Question's lettered Part (e.g.
/// "a"), or a Part's Roman-numeral Sub-part (e.g. "i") — Marking Scheme
/// Structure, Stage 1 (2026-09-22), after a real bug where a question's
/// own lettered/Roman sub-parts were flattened into independent-looking
/// rows, letting a section's "answer any N" logic miscount how many real
/// questions a candidate had actually attempted.
///
/// The same shape at every depth, recursively: only a LEAF ([children]
/// empty) stores a real, independently-entered [marks] value or its own
/// [expectedAnswerOrKeywords] — a node WITH children never stores either
/// itself, since [totalMarks] is always computed bottom-up from its
/// children. That's the one rule this class exists to enforce: editing a
/// sub-part's mark can never leave its parent question's total stale,
/// because the parent's total was never a stored number to begin with.
class MarkingSchemeNode {
  /// This node's own LOCAL label only — "2", "a", "i" — not the full
  /// composed path. See [fullLabel] for that.
  final String label;

  /// The expected answer/keywords for grading — meaningful only on a leaf;
  /// always empty for a node with children (a question that has parts
  /// doesn't itself have "an answer", only its parts do).
  final String expectedAnswerOrKeywords;

  /// This leaf's own real mark allocation — null for a node with children
  /// (see [totalMarks]), and null is also valid for an unresolved leaf
  /// (treated as 0) rather than a fabricated guess.
  final double? marks;

  final List<MarkingSchemeNode> children;

  const MarkingSchemeNode({
    required this.label,
    this.expectedAnswerOrKeywords = '',
    this.marks,
    this.children = const [],
  });

  bool get isLeaf => children.isEmpty;

  /// This node's real mark value: its own [marks] when it's a leaf
  /// (0 for an unset leaf — never a guessed number), otherwise the sum of
  /// every child's own [totalMarks], recursively. Never stored, always
  /// computed — see this class's own doc comment.
  double get totalMarks => isLeaf ? (marks ?? 0) : children.fold(0.0, (sum, c) => sum + c.totalMarks);

  /// This node's label combined with every ancestor's, in the paper's own
  /// convention — "2", then "2(a)", then "2(a)(i)". [ancestorFullLabel] is
  /// the composed label of this node's parent (or null for a top-level
  /// Question, whose full label is just its own).
  String fullLabel(String? ancestorFullLabel) =>
      ancestorFullLabel == null || ancestorFullLabel.isEmpty ? label : '$ancestorFullLabel($label)';

  /// Every LEAF beneath this node (or this node itself, if it's already a
  /// leaf), each paired with its own fully-composed label — the flat,
  /// grading-ready view every existing consumer of [MarkingSchemeQuestion]
  /// still expects (see [MarkingSchemeSection.flattenedQuestions]).
  /// [ancestorFullLabel] is this node's OWN already-composed label when
  /// called from a parent walk — pass null when calling on a genuine
  /// top-level Question.
  List<(String fullLabel, MarkingSchemeNode leaf)> leaves({String? ancestorFullLabel}) {
    final here = fullLabel(ancestorFullLabel);
    if (isLeaf) return [(here, this)];
    return [for (final c in children) ...c.leaves(ancestorFullLabel: here)];
  }

  /// Returns a copy of this whole subtree with every LEAF's [marks]
  /// replaced by whatever [byFullLabel] gives for its own composed label —
  /// a leaf whose label isn't in the map is left untouched. The one write
  /// path Stage 4's edit form needs: it only ever corrects real leaf
  /// values, never the tree's own shape, so every parent's [totalMarks]
  /// recomputes correctly for free.
  MarkingSchemeNode withUpdatedLeafMarks(Map<String, double> byFullLabel, {String? ancestorFullLabel}) {
    final here = fullLabel(ancestorFullLabel);
    if (isLeaf) {
      final updated = byFullLabel[here];
      return updated == null ? this : copyWith(marks: updated);
    }
    return copyWith(children: [for (final c in children) c.withUpdatedLeafMarks(byFullLabel, ancestorFullLabel: here)]);
  }

  /// Same idea as [withUpdatedLeafMarks], for a leaf's expected-answer
  /// text instead — lets MarkingSchemeBuilderScreen's own existing
  /// per-question answer-text editing stay usable on a tree-derived scheme
  /// without needing its own parallel editing UI.
  MarkingSchemeNode withUpdatedLeafAnswers(Map<String, String> byFullLabel, {String? ancestorFullLabel}) {
    final here = fullLabel(ancestorFullLabel);
    if (isLeaf) {
      final updated = byFullLabel[here];
      return updated == null ? this : copyWith(expectedAnswerOrKeywords: updated);
    }
    return copyWith(
      children: [for (final c in children) c.withUpdatedLeafAnswers(byFullLabel, ancestorFullLabel: here)],
    );
  }

  MarkingSchemeNode copyWith({
    String? label,
    String? expectedAnswerOrKeywords,
    double? marks,
    List<MarkingSchemeNode>? children,
  }) =>
      MarkingSchemeNode(
        label: label ?? this.label,
        expectedAnswerOrKeywords: expectedAnswerOrKeywords ?? this.expectedAnswerOrKeywords,
        marks: marks ?? this.marks,
        children: children ?? this.children,
      );

  factory MarkingSchemeNode.fromJson(Map<String, dynamic> json) => MarkingSchemeNode(
        label: json['label'] as String? ?? '',
        expectedAnswerOrKeywords: json['expectedAnswerOrKeywords'] as String? ?? '',
        marks: (json['marks'] as num?)?.toDouble(),
        children: (json['children'] as List?)
                ?.whereType<Map>()
                .map((m) => MarkingSchemeNode.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        if (expectedAnswerOrKeywords.isNotEmpty) 'expectedAnswerOrKeywords': expectedAnswerOrKeywords,
        if (marks != null) 'marks': marks,
        if (children.isNotEmpty) 'children': [for (final c in children) c.toJson()],
      };
}

/// One section of a tree-structured [MarkingScheme] — a set of top-level
/// Questions (Arabic numerals only; a Question's own Parts/Sub-parts live
/// inside its [MarkingSchemeNode.children], never as siblings here), plus
/// how many of them a candidate is actually required to answer.
class MarkingSchemeSection {
  final String name;

  /// The section's own instruction line, exactly as printed/written (e.g.
  /// "Answer any ONE question from this section") — raw record of intent,
  /// never parsed further than [requiredAnswerCount] itself.
  final String? answerInstructions;

  /// How many of [questions] (top-level Questions only) a candidate must
  /// answer — null when the section doesn't restrict it (answer every
  /// question listed).
  final int? requiredAnswerCount;

  /// Top-level Questions only (Arabic numerals) — never a Part or
  /// Sub-part directly, per this class's own doc comment.
  final List<MarkingSchemeNode> questions;

  const MarkingSchemeSection({
    required this.name,
    this.answerInstructions,
    this.requiredAnswerCount,
    this.questions = const [],
  });

  /// This section's total if every listed Question were answered in
  /// full — the sum of every top-level Question's own [MarkingSchemeNode
  /// .totalMarks]. NOT the same as what a candidate who only had to
  /// answer [requiredAnswerCount] of them is actually scored out of; see
  /// ConciseScoreCalculator for that (Stage 6) — this is purely the
  /// paper's own listed structure, used for the ingestion-time checksum
  /// (Stage 5) and the confirmation card (Stage 3).
  double get totalMarksIfAllAnswered => questions.fold(0.0, (sum, q) => sum + q.totalMarks);

  /// Every leaf question (or sub-part) in this section, flattened with its
  /// full composed label and this section's own name attached — the same
  /// shape [MarkingSchemeQuestion] already has, so every existing
  /// grading-dispatch/review consumer keeps working unchanged whether a
  /// scheme has a tree or not (see [MarkingScheme.effectiveQuestions]).
  List<MarkingSchemeQuestion> flattenedQuestions() => [
        for (final q in questions)
          for (final (fullLabel, leaf) in q.leaves())
            MarkingSchemeQuestion(
              label: fullLabel,
              expectedAnswerOrKeywords: leaf.expectedAnswerOrKeywords,
              maxMarks: leaf.marks ?? 0,
              sectionName: name,
            ),
      ];

  /// See [MarkingSchemeNode.withUpdatedLeafMarks] — applied across every
  /// top-level question in this section.
  MarkingSchemeSection withUpdatedLeafMarks(Map<String, double> byFullLabel) =>
      copyWith(questions: [for (final q in questions) q.withUpdatedLeafMarks(byFullLabel)]);

  /// See [MarkingSchemeNode.withUpdatedLeafAnswers] — applied across every
  /// top-level question in this section.
  MarkingSchemeSection withUpdatedLeafAnswers(Map<String, String> byFullLabel) =>
      copyWith(questions: [for (final q in questions) q.withUpdatedLeafAnswers(byFullLabel)]);

  MarkingSchemeSection copyWith({
    String? name,
    String? answerInstructions,
    int? requiredAnswerCount,
    List<MarkingSchemeNode>? questions,
  }) =>
      MarkingSchemeSection(
        name: name ?? this.name,
        answerInstructions: answerInstructions ?? this.answerInstructions,
        requiredAnswerCount: requiredAnswerCount ?? this.requiredAnswerCount,
        questions: questions ?? this.questions,
      );

  factory MarkingSchemeSection.fromJson(Map<String, dynamic> json) => MarkingSchemeSection(
        name: json['name'] as String? ?? '',
        answerInstructions: json['answerInstructions'] as String?,
        requiredAnswerCount: (json['requiredAnswerCount'] as num?)?.toInt(),
        questions: (json['questions'] as List?)
                ?.whereType<Map>()
                .map((m) => MarkingSchemeNode.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        if (answerInstructions != null && answerInstructions!.isNotEmpty) 'answerInstructions': answerInstructions,
        if (requiredAnswerCount != null) 'requiredAnswerCount': requiredAnswerCount,
        'questions': [for (final q in questions) q.toJson()],
      };
}
