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
