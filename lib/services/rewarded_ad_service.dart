import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Real rewarded-video-ad integration for Admin Tools' ad-gate (Word/PDF
/// Converter, Minutes Maker) — this is the concrete implementation behind
/// [EntitlementService.watchRewardedAd]'s "TODO: replace with a real
/// rewarded-ad SDK call" (that method now delegates here for these two
/// features rather than everything routing through one shared stub, since
/// Minutes Maker needs several ads back-to-back — see [showAds]).
///
/// Currently configured with Google's own public TEST ad unit IDs
/// (https://developers.google.com/admob/android/test-ads) — genuine
/// rewarded-video ad creatives served by Google's real ad infrastructure,
/// not a fake countdown standing in for one, but they can never earn real
/// revenue and can't get a real AdMob account flagged during development.
/// Swap [_rewardedAdUnitId] for a real ad unit ID once a live AdMob account
/// exists (alongside the App ID in AndroidManifest.xml — both change
/// together).
///
/// "60 seconds, uninterrupted, no skip, no early exit" is not something
/// built on top of the ad — it's how AdMob's rewarded-ad format works by
/// construction: there is no skip button, and [RewardedAd]'s
/// `onUserEarnedReward` callback only ever fires after the viewer watches
/// to completion. [showAd] simply reports whether that reward actually
/// fired.
class RewardedAdService {
  RewardedAdService._internal();
  static final RewardedAdService instance = RewardedAdService._internal();

  static const _rewardedAdUnitId = 'ca-app-pub-3940256099942544/5224354917';

  RewardedAd? _preloaded;
  bool _loading = false;

  /// Loads the next ad in the background so [showAd] doesn't have to wait
  /// on a fresh load every time — called opportunistically (e.g. when a
  /// gated screen opens), never required before [showAd], which loads
  /// on-demand if nothing was preloaded in time.
  void preload() {
    if (_preloaded != null || _loading) return;
    _loading = true;
    RewardedAd.load(
      adUnitId: _rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _loading = false;
          _preloaded = ad;
        },
        onAdFailedToLoad: (error) {
          _loading = false;
          debugPrint('RewardedAdService: failed to load ($error)');
        },
      ),
    );
  }

  Future<RewardedAd?> _takeLoadedAd({Duration timeout = const Duration(seconds: 20)}) async {
    if (_preloaded != null) {
      final ad = _preloaded!;
      _preloaded = null;
      return ad;
    }
    final completer = Completer<RewardedAd?>();
    RewardedAd.load(
      adUnitId: _rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          if (!completer.isCompleted) completer.complete(ad);
        },
        onAdFailedToLoad: (error) {
          debugPrint('RewardedAdService: failed to load ($error)');
          if (!completer.isCompleted) completer.complete(null);
        },
      ),
    );
    return completer.future.timeout(timeout, onTimeout: () => null);
  }

  /// Shows one rewarded ad and waits for the viewer to either watch it to
  /// completion (returns true) or dismiss/fail before that (returns
  /// false). Never throws — a missing ad SDK, no connection, or a load
  /// failure are all just "not unlocked", same as a viewer backing out.
  Future<bool> showAd() async {
    final ad = await _takeLoadedAd();
    if (ad == null) return false;

    final completer = Completer<bool>();
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!completer.isCompleted) completer.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        debugPrint('RewardedAdService: failed to show ($error)');
        if (!completer.isCompleted) completer.complete(false);
      },
    );

    try {
      await ad.show(
        onUserEarnedReward: (ad, reward) => earned = true,
      );
    } catch (error) {
      debugPrint('RewardedAdService: show() threw ($error)');
      if (!completer.isCompleted) completer.complete(false);
    }

    return completer.future;
  }

  /// Shows [count] rewarded ads back-to-back (Minutes Maker's Stage 6:
  /// 4 consecutive ads) — stops immediately and returns false the moment
  /// any single ad isn't watched to completion, rather than letting a
  /// skipped ad still count toward the total. [onProgress] reports how
  /// many of [count] have been fully watched so far, for a progress UI.
  Future<bool> showAds({required int count, void Function(int completed, int total)? onProgress}) async {
    for (var i = 0; i < count; i++) {
      final watched = await showAd();
      if (!watched) return false;
      onProgress?.call(i + 1, count);
    }
    return true;
  }
}
