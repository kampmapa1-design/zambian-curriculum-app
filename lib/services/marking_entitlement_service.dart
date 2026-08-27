import 'package:shared_preferences/shared_preferences.dart';

/// AI-Assisted Marking, Stage 9 — access gating distinct from the base
/// lesson-plan entitlement (see [EntitlementService]). Every other
/// gated feature in this app uses a subscription-or-watch-an-ad model;
/// that doesn't fit here, because grading a script has a real per-script
/// AI cost the moment it's sent for grading — an ad-unlock would let a
/// teacher trade thirty seconds of attention for unlimited AI spend,
/// which watching one ad doesn't come close to covering.
///
/// What's real here: a genuinely enforced local monthly free allowance
/// (see [kFreeGradingsPerMonth]) — a teacher can grade up to that many
/// scripts a month at no cost, tracked and capped for real, not a stub.
/// What's still a placeholder: the "upgrade for unlimited" path beyond
/// that allowance — this app has no real payment/store integration
/// anywhere yet (see EntitlementService's own kEntitlementEnforced
/// comment), so [recordUpgrade] exists only as the hook a real purchase
/// flow will call once that infrastructure exists.
class MarkingEntitlementService {
  MarkingEntitlementService._internal();
  static final MarkingEntitlementService instance = MarkingEntitlementService._internal();

  static const kFreeGradingsPerMonth = 5;
  static const _usageCountKey = 'marking_grading_usage_count';
  static const _usagePeriodKey = 'marking_grading_usage_period';
  static const _upgradedKey = 'marking_grading_upgraded';

  String _currentPeriodKey([DateTime? now]) {
    final n = now ?? DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}';
  }

  Future<int> _usageThisPeriod() async {
    final prefs = await SharedPreferences.getInstance();
    final storedPeriod = prefs.getString(_usagePeriodKey);
    if (storedPeriod != _currentPeriodKey()) return 0; // a new month resets the count
    return prefs.getInt(_usageCountKey) ?? 0;
  }

  Future<bool> get _upgraded async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_upgradedKey) ?? false;
  }

  /// Whether grading one more script is allowed right now — checked
  /// immediately before dispatching Stage 4's grading call, per script,
  /// not once per batch, since a batch can be partially processed
  /// (Stage 8 retries, a teacher stopping partway).
  Future<bool> canGradeAnother() async {
    if (await _upgraded) return true;
    return await _usageThisPeriod() < kFreeGradingsPerMonth;
  }

  /// How many free gradings are left this month — for showing the
  /// teacher where they stand before they hit the limit, not just after.
  Future<int> remainingFreeGradings() async {
    if (await _upgraded) return kFreeGradingsPerMonth; // unlimited in spirit; a finite display number would be misleading either way
    final used = await _usageThisPeriod();
    return (kFreeGradingsPerMonth - used).clamp(0, kFreeGradingsPerMonth);
  }

  /// Call only after a script has actually been sent for grading — not
  /// speculatively, so a check that's followed by a failed/aborted
  /// grading call doesn't burn part of the free allowance for nothing.
  Future<void> recordGradingUsed() async {
    final prefs = await SharedPreferences.getInstance();
    final period = _currentPeriodKey();
    final current = prefs.getString(_usagePeriodKey) == period ? (prefs.getInt(_usageCountKey) ?? 0) : 0;
    await prefs.setString(_usagePeriodKey, period);
    await prefs.setInt(_usageCountKey, current + 1);
  }

  /// Placeholder hook — see class doc. Not called from anywhere yet.
  Future<void> recordUpgrade() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_upgradedKey, true);
  }
}
