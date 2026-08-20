import '../models/activity_bank.dart';
import '../models/cdc_constraint_rules.dart';
import '../models/guided_answers.dart';

enum PlanningNoticeSeverity { block, warn }

/// One rule firing during [GuidedPlanningEngine.apply] — shown to the
/// teacher so an adjustment that got blocked or a lock that kicked in isn't
/// silent. `block` means the proposed adjustment was NOT applied (the
/// engine kept the safe/default value); `warn` means it was applied but is
/// surfaced as a call-out.
class PlanningNotice {
  final String ruleId;
  final PlanningNoticeSeverity severity;
  final String message;

  const PlanningNotice({required this.ruleId, required this.severity, required this.message});
}

class GuidedPlanningResult {
  final List<ActivityCandidate> selectedActivities;
  final int? suggestedGroupSize;
  final List<PlanningNotice> notices;

  const GuidedPlanningResult({
    required this.selectedActivities,
    required this.suggestedGroupSize,
    required this.notices,
  });
}

/// Stage 5: the offline, rule-based (not AI-model-dependent) engine that
/// turns a teacher's guided Q&A answers into an adjusted set of suggested
/// activities and a group size — every adjustment checked against a
/// [CdcConstraintRuleSet] loaded from assets/rules/ so no answer can
/// override a mandatory competency or silently drop required content. See
/// assets/rules/README.md for the rule-type design this implements.
class GuidedPlanningEngine {
  GuidedPlanningResult apply({
    required ActivityBank bank,
    required CdcConstraintRuleSet ruleSet,
    required GuidedAnswers answers,
  }) {
    var candidates = List<ActivityCandidate>.from(bank.activities);
    final notices = <PlanningNotice>[];
    int? groupSize;
    final answerMap = answers.asAnswerMap;

    for (final rule in ruleSet.rules) {
      switch (rule.type) {
        case RuleType.range:
          final applied = _applyRange(rule, answers, notices);
          if (applied != null) groupSize = applied;
          break;
        case RuleType.requiresFlagWhenCondition:
          candidates = _applyConditionFilter(rule, candidates, answerMap, notices);
          break;
        case RuleType.lockedIfTagged:
          candidates = _applyLockedIfTagged(rule, bank, candidates, notices);
          break;
        case RuleType.requiresCompetencyOverlap:
          candidates = _applyCompetencyOverlap(rule, bank, candidates, notices);
          break;
        case RuleType.preferenceHint:
          candidates = _applyPreferenceHint(rule, answers, candidates, notices);
          break;
      }
    }

    return GuidedPlanningResult(selectedActivities: candidates, suggestedGroupSize: groupSize, notices: notices);
  }

  int? _applyRange(CdcConstraintRule rule, GuidedAnswers answers, List<PlanningNotice> notices) {
    if (rule.appliesToField != 'group_size' || answers.classSize == null) return null;
    final min = (rule.params['min'] as num).toInt();
    final max = (rule.params['max'] as num).toInt();
    final raw = (answers.classSize! / 6).round();
    if (raw < min || raw > max) {
      notices.add(PlanningNotice(
        ruleId: rule.id,
        severity: PlanningNoticeSeverity.block,
        message: '${rule.description} (A class of ${answers.classSize} would suggest a group size of '
            '$raw, outside $min-$max — kept at $min instead.)',
      ));
      return min;
    }
    return raw;
  }

  List<ActivityCandidate> _applyConditionFilter(
    CdcConstraintRule rule,
    List<ActivityCandidate> candidates,
    Map<String, String?> answerMap,
    List<PlanningNotice> notices,
  ) {
    if (rule.appliesToField != 'activities') return candidates;
    final conditionKey = rule.params['condition_answer_key'] as String?;
    final conditionValue = rule.params['condition_answer_value'] as String?;
    final requiredTag = rule.params['required_activity_tag'] as String?;
    if (conditionKey == null || answerMap[conditionKey] != conditionValue || requiredTag == null) {
      return candidates;
    }

    bool hasTag(ActivityCandidate a) =>
        requiredTag == 'requires_no_special_aids' ? !a.requiresSpecialAids : a.styleTags.contains(requiredTag);

    final eligible = candidates.where((a) => hasTag(a) || a.foundational).toList();
    if (eligible.isEmpty) {
      notices.add(PlanningNotice(
        ruleId: rule.id,
        severity: PlanningNoticeSeverity.block,
        message: '${rule.description} (No activity in the bank qualifies, so every activity was kept '
            'rather than leaving the lesson with none.)',
      ));
      return candidates;
    }
    if (eligible.length < candidates.length) {
      notices.add(PlanningNotice(ruleId: rule.id, severity: PlanningNoticeSeverity.warn, message: rule.description));
    }
    return eligible;
  }

  List<ActivityCandidate> _applyLockedIfTagged(
    CdcConstraintRule rule,
    ActivityBank bank,
    List<ActivityCandidate> candidates,
    List<PlanningNotice> notices,
  ) {
    if (rule.appliesToField != 'activities') return candidates;
    final tag = rule.params['tag'] as String? ?? 'foundational';
    if (tag != 'foundational') return candidates;

    final selectedIds = candidates.map((a) => a.id).toSet();
    final missing = bank.activities.where((a) => a.foundational && !selectedIds.contains(a.id));
    final restored = [...candidates];
    for (final a in missing) {
      restored.add(a);
      notices.add(PlanningNotice(
        ruleId: rule.id,
        severity: PlanningNoticeSeverity.warn,
        message: '${rule.description} ("${a.description}" kept regardless of other answers.)',
      ));
    }
    return restored;
  }

  List<ActivityCandidate> _applyCompetencyOverlap(
    CdcConstraintRule rule,
    ActivityBank bank,
    List<ActivityCandidate> candidates,
    List<PlanningNotice> notices,
  ) {
    if (rule.appliesToField != 'activities' || bank.competencyTags.isEmpty) return candidates;
    final coversRequired = candidates.any((a) => a.competencyTags.any(bank.competencyTags.contains));
    if (coversRequired) return candidates;

    ActivityCandidate? fallback;
    for (final a in bank.activities) {
      if (a.competencyTags.any(bank.competencyTags.contains)) {
        fallback = a;
        break;
      }
    }
    if (fallback == null) return candidates;
    notices.add(PlanningNotice(
      ruleId: rule.id,
      severity: PlanningNoticeSeverity.block,
      message: '${rule.description} ("${fallback.description}" restored so the lesson still covers '
          '${bank.competencyTags.join(", ")}.)',
    ));
    return [...candidates, fallback];
  }

  List<ActivityCandidate> _applyPreferenceHint(
    CdcConstraintRule rule,
    GuidedAnswers answers,
    List<ActivityCandidate> candidates,
    List<PlanningNotice> notices,
  ) {
    if (rule.appliesToField != 'activities' || answers.preferredStyle == ActivityStylePreference.noPreference) {
      return candidates;
    }
    final wantedTag = answers.preferredStyle == ActivityStylePreference.groupWork ? 'group_work' : 'individual';
    final reordered = [...candidates]
      ..sort((a, b) {
        final aMatch = a.styleTags.contains(wantedTag) ? 0 : 1;
        final bMatch = b.styleTags.contains(wantedTag) ? 0 : 1;
        return aMatch.compareTo(bMatch);
      });
    final changed = List.generate(candidates.length, (i) => candidates[i].id != reordered[i].id).contains(true);
    if (changed) {
      notices.add(PlanningNotice(ruleId: rule.id, severity: PlanningNoticeSeverity.warn, message: rule.description));
    }
    return reordered;
  }
}
