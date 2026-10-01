import '../models/marking_scheme_node.dart';

/// Parses the tree-shaped `sections` array `deriveMarkingKeyFromQuestionPaper`
/// returns (Marking Scheme Structure Stage 2, 2026-09-22) into
/// [MarkingSchemeSection]s — pure, no I/O, so it's directly unit-testable
/// against hand-built JSON without mocking Firebase Functions (the same
/// reasoning as this codebase's other server-response parsers, e.g.
/// RequiredCoreTopicService.generate's own defensive `is` checks).
///
/// Defensive throughout: a malformed/missing field degrades that one
/// node/section (or is skipped) rather than throwing and losing the whole
/// document's real extracted structure.
List<MarkingSchemeSection> parseMarkingKeySectionTree(Object? sectionsRaw) {
  if (sectionsRaw is! List) return const [];
  final sections = <MarkingSchemeSection>[];
  for (final raw in sectionsRaw) {
    if (raw is! Map) continue;
    final name = raw['name'];
    final instructionsRaw = raw['answerInstructions'];
    final requiredRaw = raw['requiredAnswerCount'];
    final questionsRaw = raw['questions'];
    sections.add(MarkingSchemeSection(
      name: name is String ? name.trim() : '',
      answerInstructions: instructionsRaw is String && instructionsRaw.trim().isNotEmpty ? instructionsRaw.trim() : null,
      requiredAnswerCount: requiredRaw is num ? requiredRaw.toInt() : null,
      questions: questionsRaw is List
          ? [for (final q in questionsRaw) if (q is Map) _parseNode(q, childrenKey: 'parts')]
          : const [],
    ));
  }
  return sections;
}

/// One node: a top-level Question (children under `parts`) or a Part
/// (children under `subParts`) — the caller says which key to look under
/// so this same function handles both of the schema's two nesting levels.
MarkingSchemeNode _parseNode(Map raw, {required String childrenKey}) {
  final label = raw['label'];
  final expected = raw['expectedAnswerOrKeywords'];
  final marks = raw['marks'];
  final childrenRaw = raw[childrenKey];
  final children = childrenRaw is List
      ? [
          for (final c in childrenRaw)
            if (c is Map) _parseNode(c, childrenKey: childrenKey == 'parts' ? 'subParts' : 'subParts')
        ]
      : const <MarkingSchemeNode>[];
  return MarkingSchemeNode(
    label: label is String ? label.trim() : '',
    expectedAnswerOrKeywords: expected is String ? expected : '',
    marks: marks is num ? marks.toDouble() : null,
    children: children,
  );
}
