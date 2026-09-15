import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Whether the free-tier monthly caps actually block generation. **Off**
/// by explicit decision (2026-09-14, same call as this app's other
/// entitlement flags — see MarkingEntitlementService.kGradingCapEnforced
/// for the standing rationale): usage is tracked for real starting now,
/// nothing is blocked until a real payment path exists and this is
/// flipped to `true`.
const bool kFreeTierCapEnforced = false;

enum FreeTierFeature {
  lessonPlan,
  schemeOfWork,
  timetableGeneration;

  int get monthlyLimit => switch (this) {
        FreeTierFeature.lessonPlan => 4,
        FreeTierFeature.schemeOfWork => 2,
        FreeTierFeature.timetableGeneration => 1,
      };

  String get _usageCountKey => 'freetier_${name}_usage_count';
  String get _usagePeriodKey => 'freetier_${name}_usage_period';
}

/// Home Assignment epic, Stage 3 (added 2026-09-14) — "Define a 'Free
/// Tier' as the default state for any unregistered/unsubscribed
/// Teacher-role account." Deliberately separate from `School`'s
/// subscriptionTier (School Network's Gold/Institutional gate on
/// TIMETABLE MANAGEMENT for a whole school): this is a per-device,
/// per-teacher allowance that applies whether or not that teacher
/// belongs to any school at all — confirmed via research that no
/// existing per-teacher (non-school) subscription concept exists yet.
/// Same on-device SharedPreferences + "$year-$month" period-key pattern
/// as [MarkingEntitlementService], one counter per [FreeTierFeature].
class FreeTierEntitlementService {
  FreeTierEntitlementService._internal();
  static final FreeTierEntitlementService instance = FreeTierEntitlementService._internal();

  String _currentPeriodKey([DateTime? now]) {
    final n = now ?? DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}';
  }

  Future<int> _usageThisPeriod(FreeTierFeature feature) async {
    final prefs = await SharedPreferences.getInstance();
    final storedPeriod = prefs.getString(feature._usagePeriodKey);
    if (storedPeriod != _currentPeriodKey()) return 0; // a new month resets the count
    return prefs.getInt(feature._usageCountKey) ?? 0;
  }

  /// Whether one more use of [feature] is allowed right now.
  Future<bool> canUse(FreeTierFeature feature) async {
    if (!kFreeTierCapEnforced) return true;
    return await _usageThisPeriod(feature) < feature.monthlyLimit;
  }

  /// How many uses of [feature] are left this month.
  Future<int> remaining(FreeTierFeature feature) async {
    final used = await _usageThisPeriod(feature);
    return (feature.monthlyLimit - used).clamp(0, feature.monthlyLimit);
  }

  /// Call only after generation has actually succeeded — not
  /// speculatively, same discipline as MarkingEntitlementService's own
  /// recordGradingUsed.
  Future<void> recordUsed(FreeTierFeature feature) async {
    final prefs = await SharedPreferences.getInstance();
    final period = _currentPeriodKey();
    final current = prefs.getString(feature._usagePeriodKey) == period ? (prefs.getInt(feature._usageCountKey) ?? 0) : 0;
    await prefs.setString(feature._usagePeriodKey, period);
    await prefs.setInt(feature._usageCountKey, current + 1);
  }

  // -------------------------------------------------------------------
  // Scheme of Work's own extra restriction: "restricted to 2 subjects
  // the teacher selects once (locked until next month)." Kept separate
  // from the generic counter above since it's a SET of allowed subjects,
  // not a count.
  // -------------------------------------------------------------------

  static const _schemeSubjectsKey = 'freetier_scheme_subjects';
  static const _schemeSubjectsPeriodKey = 'freetier_scheme_subjects_period';

  /// The up-to-2 subjects locked in for Scheme of Work this month — empty
  /// if the teacher hasn't generated a scheme yet this month (nothing
  /// locked yet, any subject is still fair game to become one of the 2).
  Future<List<String>> lockedSchemeSubjects() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_schemeSubjectsPeriodKey) != _currentPeriodKey()) return const [];
    final raw = prefs.getString(_schemeSubjectsKey);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }

  /// True if [subjectName] can be used for a Scheme of Work generation
  /// this month under the current lock — either nothing is locked yet
  /// (this subject would become one of the 2), or it's already one of
  /// the locked subjects. Does NOT itself lock anything — call
  /// [lockSchemeSubject] only once generation actually succeeds.
  Future<bool> isSchemeSubjectAllowed(String subjectName) async {
    if (!kFreeTierCapEnforced) return true;
    final locked = await lockedSchemeSubjects();
    return locked.isEmpty || locked.contains(subjectName) || locked.length < 2;
  }

  /// Call after a successful Scheme of Work generation — adds
  /// [subjectName] to this month's lock if it isn't already there and
  /// there's still room (max 2). A subject already locked, or a month
  /// with both slots already used by two OTHER subjects, is a no-op.
  Future<void> lockSchemeSubject(String subjectName) async {
    final prefs = await SharedPreferences.getInstance();
    final period = _currentPeriodKey();
    final current = prefs.getString(_schemeSubjectsPeriodKey) == period ? await lockedSchemeSubjects() : <String>[];
    if (current.contains(subjectName) || current.length >= 2) {
      // Still persist the period even on a no-op locking attempt, so an
      // empty-but-current-month state is distinguishable from "never
      // touched this month" — harmless either way since reads already
      // treat a stale period as empty.
      await prefs.setString(_schemeSubjectsPeriodKey, period);
      return;
    }
    await prefs.setString(_schemeSubjectsPeriodKey, period);
    await prefs.setString(_schemeSubjectsKey, jsonEncode([...current, subjectName]));
  }
}
