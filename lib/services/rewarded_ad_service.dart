// REMOVED (2026-08-30): google_mobile_ads was confirmed — via two isolated
// diagnostic test builds on a real device (Moto G05) — to be the root
// cause of an app-wide crash-on-launch. Real integration lived here on a
// prior commit (see `git log -- lib/services/rewarded_ad_service.dart`)
// and used Google's public TEST ad unit IDs. Pulled out entirely rather
// than left half-working, since `kEntitlementEnforced = false` means no
// screen actually needs a real ad right now anyway — this stub costs
// nothing functionally while it's out.
//
// To bring ads back for real: pin an exact `google_mobile_ads` version,
// test a release build against multiple real devices (not just one)
// before shipping, and only then restore the real RewardedAd/AdRequest
// implementation this class used to have.

/// Stub standing in for a real rewarded-ad SDK — see file header. Always
/// reports the ad as "watched" instantly; no ad SDK involved, no crash
/// risk, and no lost revenue — AdMob was always on Google's public test
/// ad unit IDs here, so it never earned anything real to begin with.
class RewardedAdService {
  RewardedAdService._internal();
  static final RewardedAdService instance = RewardedAdService._internal();

  void preload() {}

  Future<bool> showAd() async => true;

  Future<bool> showAds({required int count, void Function(int completed, int total)? onProgress}) async {
    for (var i = 0; i < count; i++) {
      onProgress?.call(i + 1, count);
    }
    return true;
  }
}

/// How an attempt to earn an ad pass ended.
enum AdPassResult {
  /// The ad played to completion; the server will mint the pass once AdMob's
  /// signed callback reaches it (usually within seconds).
  earned,

  /// The teacher closed the ad early — no reward.
  dismissed,

  /// Ads can't be shown in this build/on this device.
  unavailable,
}

/// The seam through which an ad pass is earned. A pass can ONLY be created by
/// Google's signed AdMob server-side callback (see firebase/functions/src/adPass.ts),
/// never by this client saying "the ad played" — so a real implementation must
/// attach the Firebase uid as the ad's server-side-verification user id, and
/// the stub below deliberately does NOT claim success.
///
/// Currently a stub: no ad SDK is in the app (see [RewardedAdService]'s header
/// for why), so [supportsAdPasses] is false, the "watch an ad" option is never
/// offered, and no generation can be paid for with an ad. Re-integrating a real
/// SDK means implementing this and nothing else about the flow.
class AdPassEarner {
  AdPassEarner._();
  static final AdPassEarner instance = AdPassEarner._();

  /// Whether the "watch an ad" option can be offered at all.
  bool get supportsAdPasses => false;

  /// Shows one rewarded ad for [uid]. See the class comment.
  Future<AdPassResult> showForPass({required String uid}) async => AdPassResult.unavailable;
}
