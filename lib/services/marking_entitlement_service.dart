import '../models/marking_credits.dart';
import 'marking_credits_service.dart';

/// Whether the teacher can afford to mark another script — now driven by the
/// server-authoritative marking-credit ledger (Monetization, 2026-09-19),
/// replacing the old phone-side "5 free gradings a month" counter. That
/// counter lived in SharedPreferences, so clearing app data reset it; it was
/// also switched off entirely (`kGradingCapEnforced = false`). Neither is
/// acceptable once credits cost real money, so nothing about the balance is
/// stored or counted on the device any more: the Cloud Function checks and
/// charges, and the app only READS the result.
///
/// Everything here is a COURTESY check that saves a pointless network round
/// trip (and a wasted photo upload) when the last-known balance clearly can't
/// cover the script. It never blocks when the balance or config is unknown,
/// and it never blocks unless credits are switched to "enforced" in the
/// remote config — the server is the real gate either way.
class MarkingEntitlementService {
  MarkingEntitlementService._internal();
  static final MarkingEntitlementService instance = MarkingEntitlementService._internal();

  /// Whether [pages] pages on [engine] look affordable right now.
  Future<bool> canGradeAnother({MarkingEngineKind engine = MarkingEngineKind.keyed, int pages = 1}) async =>
      MarkingCreditsService.instance.canAfford(engine, pages);

  /// The teacher's spendable credits (free + purchased) as last known, or
  /// null when unknown or credits aren't switched on — for a small balance
  /// line on the marking screens.
  double? spendableCreditsIfEnforced({DateTime? now}) {
    final config = MarkingCreditsService.instance.cachedConfig;
    final balance = MarkingCreditsService.instance.cachedBalance;
    if (config == null || balance == null || !config.isEnforced) return null;
    return balance.spendable(config, now ?? DateTime.now());
  }
}
