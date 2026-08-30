import 'package:connectivity_plus/connectivity_plus.dart';

import 'rewarded_ad_service.dart';

/// Whether the entitlement gate actually blocks generation. [verifySubscription]
/// and [watchRewardedAd] are still unimplemented placeholders (no real store
/// or ad SDK wired up yet — see class doc), so with this left `true` nobody
/// could ever pass the gate in a release build: every export would silently
/// show nothing rather than "insufficient entitlement," which is exactly the
/// bug this flag exists to avoid. Flip back to `true` once a real
/// in_app_purchase/google_mobile_ads backend replaces those placeholders.
const bool kEntitlementEnforced = false;

/// A subscription verification cached from the last time it was confirmed
/// online. [gracePeriod] is how long that verification stays trusted while
/// offline before the app requires going online to reverify.
class SubscriptionRecord {
  final DateTime lastVerifiedAt;
  final Duration gracePeriod;

  const SubscriptionRecord({
    required this.lastVerifiedAt,
    this.gracePeriod = const Duration(days: 3),
  });

  bool isWithinGracePeriod([DateTime? now]) =>
      (now ?? DateTime.now()).isBefore(lastVerifiedAt.add(gracePeriod));
}

class GenerationAccessResult {
  final bool allowed;
  final String? message;

  const GenerationAccessResult({required this.allowed, this.message});
}

/// Gates access to generated content (the scheme of work) on having an
/// entitlement — an unexpired subscription verification, or an ad-unlock
/// granted earlier this session.
///
/// The actual subscription check, ad-watching, and purchase flows are
/// stubbed: [verifySubscription] and [watchRewardedAd] are placeholders to
/// wire up a real store/ad SDK (in_app_purchase, google_mobile_ads) against.
/// Everything else here — grace-period math, session ad-unlock tracking, and
/// the offline gating rules — is real and does not depend on those SDKs.
class EntitlementService {
  EntitlementService._internal();
  static final EntitlementService instance = EntitlementService._internal();

  SubscriptionRecord? _subscription;
  bool _adUnlockedThisSession = false;

  bool get hasLocalEntitlement =>
      (_subscription?.isWithinGracePeriod() ?? false) || _adUnlockedThisSession;

  /// Whether any ad-gate in the app should actually require watching an
  /// ad right now — the single switch for "are ads on or off," covering
  /// every gated feature (Scheme of Work, Word/PDF Converter, Minutes
  /// Maker) consistently. `false` whenever [kEntitlementEnforced] is off
  /// (the current, deliberate state — see that flag's own doc comment) or
  /// the user already has a local entitlement. Screens should check this,
  /// not [hasLocalEntitlement] directly, when deciding whether to show
  /// the ad-gate at all — [hasLocalEntitlement] alone doesn't account for
  /// [kEntitlementEnforced], which is exactly the bug this fixes (Word/PDF
  /// Converter and Minutes Maker were checking [hasLocalEntitlement] only,
  /// so their ad requirement stayed live even with enforcement off).
  bool get adGateBypassed => !kEntitlementEnforced || hasLocalEntitlement;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// Whether the scheme of work may be generated right now. Offline, this
  /// falls back to a subscription still within its grace period or a
  /// session ad-unlock — both avoid needing a live connection.
  Future<GenerationAccessResult> checkGenerationAccess() async {
    if (!kEntitlementEnforced || hasLocalEntitlement) {
      return const GenerationAccessResult(allowed: true);
    }

    if (await isOnline) {
      return const GenerationAccessResult(
        allowed: false,
        message: "Subscribe or watch a short ad to unlock this term's scheme of work.",
      );
    }

    return const GenerationAccessResult(
      allowed: false,
      message: "You're offline and don't have an active pass. Connect to the internet "
          'to subscribe or watch an ad, then come back to generate your scheme of work.',
    );
  }

  /// TODO: replace with a real store receipt/subscription check. Requires
  /// internet — throws if called offline, matching the "block new purchases
  /// while offline" rule.
  Future<void> verifySubscription() async {
    if (!await isOnline) {
      throw StateError('Cannot start a purchase while offline.');
    }
    // Placeholder: a real implementation validates a receipt/token here and
    // sets the grace period from the store's response.
    _subscription = SubscriptionRecord(lastVerifiedAt: DateTime.now());
  }

  /// Real rewarded-ad call (see [RewardedAdService]) — throws if called
  /// offline, matching the "block new ad-watching while offline" rule.
  /// Returns false (without unlocking) if the ad was shown but not
  /// watched to completion, rather than throwing — a dismissed ad isn't
  /// an error, just "not unlocked yet."
  Future<bool> watchRewardedAd() async {
    if (!await isOnline) {
      throw StateError('Cannot watch an ad while offline.');
    }
    final watched = await RewardedAdService.instance.showAd();
    if (watched) _adUnlockedThisSession = true;
    return watched;
  }
}
