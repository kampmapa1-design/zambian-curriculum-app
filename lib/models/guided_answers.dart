enum ActivityStylePreference { groupWork, individual, noPreference }

enum PriorMastery { low, medium, high }

/// A teacher's answers to the Stage 5 guided Q&A — the input the rules
/// engine (see [CdcConstraintRuleSet] / GuidedPlanningEngine) checks every
/// proposed adjustment against.
class GuidedAnswers {
  final int? classSize;
  final bool? teachingAidsAvailable;
  final PriorMastery? priorMastery;
  final ActivityStylePreference preferredStyle;

  const GuidedAnswers({
    this.classSize,
    this.teachingAidsAvailable,
    this.priorMastery,
    this.preferredStyle = ActivityStylePreference.noPreference,
  });

  /// String-keyed view of the answers, matching the `condition_answer_key`/
  /// `condition_answer_value` shape rules files use — keeps the engine's
  /// rule dispatch generic instead of hardcoding field names per rule.
  Map<String, String?> get asAnswerMap => {
        'available_teaching_aids': teachingAidsAvailable == null ? null : (teachingAidsAvailable! ? 'available' : 'none'),
        'prior_mastery': priorMastery?.name,
        'preferred_style': preferredStyle == ActivityStylePreference.noPreference ? null : preferredStyle.name,
      };
}
