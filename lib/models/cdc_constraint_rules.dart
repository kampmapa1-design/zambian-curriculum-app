/// Parses rules files shaped like assets/rules/cdc_constraints.example.json
/// (see assets/rules/README.md for the full design). One [CdcConstraintRuleSet]
/// per curriculum, since what's mandatory can differ between the 2023 CBC
/// and the 2013 OBC.
enum RuleSeverity { block, warn }

enum RuleType { requiresCompetencyOverlap, range, requiresFlagWhenCondition, lockedIfTagged, preferenceHint }

RuleType _parseRuleType(String raw) {
  switch (raw) {
    case 'requires_competency_overlap':
      return RuleType.requiresCompetencyOverlap;
    case 'range':
      return RuleType.range;
    case 'requires_flag_when_condition':
      return RuleType.requiresFlagWhenCondition;
    case 'locked_if_tagged':
      return RuleType.lockedIfTagged;
    case 'preference_hint':
      return RuleType.preferenceHint;
    default:
      throw FormatException('Unknown CDC constraint rule type: $raw');
  }
}

class CdcConstraintRule {
  final String id;
  final String appliesToField;
  final RuleType type;
  final RuleSeverity severity;
  final String description;
  final Map<String, dynamic> params;

  const CdcConstraintRule({
    required this.id,
    required this.appliesToField,
    required this.type,
    required this.severity,
    required this.description,
    required this.params,
  });

  factory CdcConstraintRule.fromJson(Map<String, dynamic> json) => CdcConstraintRule(
        id: json['id'] as String,
        appliesToField: json['applies_to_field'] as String,
        type: _parseRuleType(json['type'] as String),
        severity: (json['severity'] as String) == 'block' ? RuleSeverity.block : RuleSeverity.warn,
        description: json['description'] as String,
        params: (json['params'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

class CdcConstraintRuleSet {
  final String curriculumCode;
  final int version;
  final List<String> lockedTemplateSections;
  final List<CdcConstraintRule> rules;

  const CdcConstraintRuleSet({
    required this.curriculumCode,
    required this.version,
    required this.lockedTemplateSections,
    required this.rules,
  });

  factory CdcConstraintRuleSet.fromJson(Map<String, dynamic> json) => CdcConstraintRuleSet(
        curriculumCode: json['curriculum_code'] as String,
        version: json['version'] as int,
        lockedTemplateSections: (json['locked_template_sections'] as List? ?? const []).cast<String>(),
        rules: [
          for (final r in (json['rules'] as List).cast<Map<String, dynamic>>()) CdcConstraintRule.fromJson(r)
        ],
      );
}
