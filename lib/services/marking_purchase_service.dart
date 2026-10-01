import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'marking_credits_service.dart';

enum PurchaseOutcomeKind {
  /// Credits were added.
  credited,

  /// The purchase was already credited before (a re-delivery) — nothing more added.
  alreadyCredited,

  /// Payment is still processing, or verification isn't ready — will be retried.
  pending,

  /// The teacher must sign in before the credits can be added.
  needsSignIn,

  /// The teacher backed out of the Play dialog.
  cancelled,

  /// Failed and will not succeed by retrying.
  failed,
}

class PurchaseOutcome {
  final PurchaseOutcomeKind kind;
  final String message;
  final double credits;

  const PurchaseOutcome(this.kind, this.message, {this.credits = 0});
}

/// The bits of a Play purchase this flow needs — decoupled from the plugin's
/// classes so the important rule (below) is unit-testable.
class PurchaseInfo {
  final String productId;
  final String purchaseToken;

  /// pending | purchased (or restored) | error | canceled
  final String status;
  final String? errorMessage;

  const PurchaseInfo({required this.productId, required this.purchaseToken, required this.status, this.errorMessage});
}

/// THE rule of buying credits: a purchase is only CONSUMED (which frees the
/// product to be bought again and finalises the sale with Google) AFTER the
/// server has verified it and credited the account. If anything fails
/// before that, the purchase is left un-consumed on purpose, so the next
/// recovery pass (or app start) redeems it again — money is never taken
/// without the credits eventually arriving. (Google refunds a purchase that
/// is not acknowledged/consumed within 3 days, so an unfixable one refunds
/// itself rather than sitting as paid-but-undelivered.)
class PurchaseProcessor {
  PurchaseProcessor({required this.redeem, required this.consume});

  final Future<RedeemOutcome> Function(String productId, String purchaseToken) redeem;
  final Future<void> Function(PurchaseInfo purchase) consume;

  /// Tokens currently being redeemed — the plugin can deliver the same purchase twice at once.
  final Set<String> _inFlight = {};

  Future<PurchaseOutcome?> process(PurchaseInfo p) async {
    switch (p.status) {
      case 'pending':
        return const PurchaseOutcome(PurchaseOutcomeKind.pending, 'Your payment is still processing. Credits will be added as soon as it completes.');
      case 'canceled':
        return const PurchaseOutcome(PurchaseOutcomeKind.cancelled, 'Purchase cancelled — you were not charged.');
      case 'error':
        return PurchaseOutcome(PurchaseOutcomeKind.failed, p.errorMessage ?? 'The purchase did not go through.');
    }

    if (!_inFlight.add(p.purchaseToken)) return null; // already being handled
    try {
      final RedeemOutcome outcome;
      try {
        outcome = await redeem(p.productId, p.purchaseToken);
      } on CreditRedeemException catch (e) {
        if (e.needsSignIn) return PurchaseOutcome(PurchaseOutcomeKind.needsSignIn, e.message);
        if (e.retryable) return PurchaseOutcome(PurchaseOutcomeKind.pending, e.message);
        return PurchaseOutcome(PurchaseOutcomeKind.failed, e.message);
      }
      try {
        await consume(p);
      } catch (_) {
        // Credited but not yet consumed: harmless — the next recovery pass
        // redeems it again (a no-op duplicate) and retries the consume.
      }
      return outcome.duplicate
          ? const PurchaseOutcome(PurchaseOutcomeKind.alreadyCredited, 'That purchase was already added to your credits.')
          : PurchaseOutcome(
              PurchaseOutcomeKind.credited,
              'Added ${_fmt(outcome.creditsGranted)} marking credits.',
              credits: outcome.creditsGranted,
            );
    } finally {
      _inFlight.remove(p.purchaseToken);
    }
  }

  static String _fmt(double c) => c == c.roundToDouble() ? c.toStringAsFixed(0) : c.toStringAsFixed(1);
}

/// Wraps Google Play Billing for the marking-credit bundles. Bundles are
/// CONSUMABLE products, so the same one can be bought again and again.
class MarkingPurchaseService {
  MarkingPurchaseService({InAppPurchase? iap, MarkingCreditsService? credits})
      : _iapOverride = iap,
        _credits = credits ?? MarkingCreditsService.instance {
    _processor = PurchaseProcessor(
      redeem: (productId, token) => _credits.redeemPurchase(productId: productId, purchaseToken: token),
      consume: _consume,
    );
  }

  static final MarkingPurchaseService instance = MarkingPurchaseService();

  final InAppPurchase? _iapOverride;
  final MarkingCreditsService _credits;
  late final PurchaseProcessor _processor;
  InAppPurchase get _iap => _iapOverride ?? InAppPurchase.instance;

  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final StreamController<PurchaseOutcome> _outcomes = StreamController<PurchaseOutcome>.broadcast();

  /// What happened to each purchase — the credits screen shows these as messages.
  Stream<PurchaseOutcome> get outcomes => _outcomes.stream;

  /// Begin listening for purchase updates (idempotent).
  void start() {
    _subscription ??= _iap.purchaseStream.listen(
      (purchases) {
        for (final p in purchases) {
          unawaited(_handle(p));
        }
      },
      onError: (Object error) => _outcomes.add(PurchaseOutcome(PurchaseOutcomeKind.failed, 'Play Billing error: $error')),
    );
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<bool> get isAvailable async {
    try {
      return await _iap.isAvailable();
    } catch (_) {
      return false;
    }
  }

  /// The products Play knows about for [ids] (empty when the store or the
  /// products aren't set up yet — the screen then says so instead of failing).
  Future<List<ProductDetails>> loadProducts(Set<String> ids) async {
    if (ids.isEmpty || !await isAvailable) return const [];
    try {
      final response = await _iap.queryProductDetails(ids);
      return response.productDetails;
    } catch (_) {
      return const [];
    }
  }

  /// Opens the Play purchase dialog. The account id sent with it is a hash of
  /// the uid; the server refuses a purchase that doesn't match the account
  /// redeeming it. Returns false if the dialog couldn't be launched.
  Future<bool> buy(ProductDetails product) async {
    start();
    final uid = await _credits.currentUid();
    final param = PurchaseParam(productDetails: product, applicationUserName: obfuscatedAccountIdFor(uid));
    // autoConsume:false — we consume ONLY after the server has credited it.
    return _iap.buyConsumable(purchaseParam: param, autoConsume: false);
  }

  /// Re-delivers any purchase that was paid for but never credited (the
  /// phone died mid-purchase, no signal at the time, etc.). Play only lists
  /// UN-consumed purchases, which is exactly the set that still needs crediting.
  Future<void> recoverPending() async {
    start();
    try {
      await _iap.restorePurchases();
    } catch (e) {
      debugPrint('MarkingPurchaseService.recoverPending failed: $e');
    }
  }

  Future<void> _handle(PurchaseDetails purchase) async {
    final outcome = await _processor.process(PurchaseInfo(
      productId: purchase.productID,
      purchaseToken: purchase.verificationData.serverVerificationData,
      status: switch (purchase.status) {
        PurchaseStatus.pending => 'pending',
        PurchaseStatus.error => 'error',
        PurchaseStatus.canceled => 'canceled',
        PurchaseStatus.purchased || PurchaseStatus.restored => 'purchased',
      },
      errorMessage: purchase.error?.message,
    ));
    if (outcome != null) _outcomes.add(outcome);
  }

  Future<void> _consume(PurchaseInfo p) async {
    final addition = _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    // The plugin's consume takes the PurchaseDetails, but only reads its token —
    // so a minimal one carrying that token is enough.
    await addition.consumePurchase(
      PurchaseDetails(
        productID: p.productId,
        verificationData: PurchaseVerificationData(
          localVerificationData: p.purchaseToken,
          serverVerificationData: p.purchaseToken,
          source: 'google_play',
        ),
        transactionDate: null,
        status: PurchaseStatus.purchased,
      ),
    );
  }
}
