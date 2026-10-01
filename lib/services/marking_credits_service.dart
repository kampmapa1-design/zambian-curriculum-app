import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/marking_credits.dart';
import 'auth_service.dart';

/// Turns the server's "not enough credits" refusal into a typed exception.
/// Pure (takes the raw pieces of a [FirebaseFunctionsException]) so it can be
/// unit-tested without Firebase. Returns null for any other error.
InsufficientCreditsException? insufficientCreditsFrom({required String code, Object? details, String? message}) {
  if (code != 'failed-precondition' || details is! Map || details['code'] != 'insufficient_credits') return null;
  double num0(Object? v) => v is num ? v.toDouble() : 0;
  return InsufficientCreditsException(
    requiredCredits: num0(details['requiredCredits']),
    availableCredits: num0(details['availableCredits']),
    message: message ?? 'Not enough marking credits for this script.',
    feature: details['feature'] is String ? details['feature'] as String : null,
    adPassEligible: details['adPassEligible'] == true,
  );
}

/// Convenience for the two grading services' `on FirebaseFunctionsException`.
InsufficientCreditsException? insufficientCreditsFromException(FirebaseFunctionsException e) =>
    insufficientCreditsFrom(code: e.code, details: e.details, message: e.message);

/// The account id attached to a Play purchase — MUST match the server's
/// `obfuscatedAccountId` (sha256("play-account:<uid>"), first 40 hex chars).
/// A hash, never the raw uid; the server refuses a purchase whose id doesn't
/// match the account redeeming it.
String obfuscatedAccountIdFor(String uid) => sha256.convert(utf8.encode('play-account:$uid')).toString().substring(0, 40);

/// One id per user-initiated marking action, REUSED across every retry of
/// that same action, so a script the server already charged is never charged
/// again when the phone retries after a lost response. (In memory only: a
/// fresh id after an app restart is acceptable — the worst case is one
/// repeat charge after a crash mid-marking.)
class MarkingRequestIds {
  MarkingRequestIds._();

  static final Map<String, String> _ids = {};
  static final Random _random = Random.secure();

  /// The id for [key] (e.g. a script id), creating it on first use.
  static String forKey(String key) => _ids.putIfAbsent(key, _newId);

  /// A brand-new id, for a one-off action that has no natural key (a feature
  /// generation): protects against the same call being delivered twice.
  static String fresh() => _newId();

  /// Forget [key] once its script has been marked successfully — the NEXT
  /// marking of the same script is a new, separately-charged action.
  static void clear(String key) => _ids.remove(key);

  static String _newId() {
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final r = List.generate(4, (_) => _random.nextInt(1 << 16).toRadixString(16).padLeft(4, '0')).join();
    return 'm$t-$r';
  }

  @visibleForTesting
  static void resetForTest() => _ids.clear();
}

/// Reads the live credit config and the teacher's own ledger (both read-only
/// Firestore documents — see firestore.rules), and redeems Play purchases via
/// the `redeemMarkingBundle` Cloud Function. The server is the only thing
/// that ever changes a balance.
class MarkingCreditsService {
  MarkingCreditsService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestoreOverride = firestore,
        _functionsOverride = functions;

  static final MarkingCreditsService instance = MarkingCreditsService();

  final FirebaseFirestore? _firestoreOverride;
  final FirebaseFunctions? _functionsOverride;
  FirebaseFirestore get _firestore => _firestoreOverride ?? FirebaseFirestore.instance;
  FirebaseFunctions get _functions => _functionsOverride ?? FirebaseFunctions.instance;

  MarkingCreditsConfig? _config;
  CreditBalance? _balance;

  /// Last known config/balance, or null before the first [refresh] — callers
  /// treat null as "unknown, let the server decide".
  MarkingCreditsConfig? get cachedConfig => _config;
  CreditBalance? get cachedBalance => _balance;

  @visibleForTesting
  void seedForTest({MarkingCreditsConfig? config, CreditBalance? balance}) {
    _config = config;
    _balance = balance;
  }

  /// Records the balance the server reported after charging a script, so the
  /// courtesy check in a long batch stays current without another read. The
  /// server reports one combined figure, so it is held as "purchased" with no
  /// free part — [CreditBalance.spendable] adds them, so the total is right.
  void noteSpendableBalance(double balance, {DateTime? now}) {
    _balance = CreditBalance(freeCredits: 0, purchasedCredits: balance, freePeriod: periodKeyCat(now ?? DateTime.now()));
  }

  /// Courtesy pre-check before a network call: false ONLY when credits are
  /// enforced and the last-known balance clearly can't cover [pages] pages.
  /// Unknown config or balance → true (the server is the real gate).
  bool canAfford(MarkingEngineKind engine, int pages, {DateTime? now}) {
    final config = _config;
    final balance = _balance;
    if (config == null || balance == null || !config.isEnforced) return true;
    final t = now ?? DateTime.now();
    return balance.spendable(config, t) + 1e-9 >= config.costFor(engine, pages, t);
  }

  Future<String> currentUid() async => (await AuthService.instance.ensureSignedIn()).uid;

  Future<MarkingCreditsConfig> loadConfig() async {
    try {
      await AuthService.instance.ensureSignedIn();
      final snap = await _firestore.doc('appConfig/markingCredits').get();
      _config = snap.exists ? MarkingCreditsConfig.fromMap(snap.data()) : MarkingCreditsConfig.defaults;
    } catch (_) {
      // Offline / rules / missing — keep the last good copy, else the safe default (mode 'off').
      _config ??= MarkingCreditsConfig.defaults;
    }
    return _config!;
  }

  /// Live balance for the credits screen. Emits [CreditBalance.empty] for a
  /// teacher with no ledger yet (nothing bought, nothing marked).
  Stream<CreditBalance> watchBalance() async* {
    final uid = await currentUid();
    yield* _firestore.doc('creditLedgers/user_$uid').snapshots().map((snap) {
      final b = snap.exists ? CreditBalance.fromMap(snap.data() ?? const {}) : CreditBalance.empty;
      _balance = b;
      return b;
    });
  }

  /// One-shot refresh of config + balance into the caches (used before marking).
  Future<void> refresh() async {
    await loadConfig();
    try {
      final uid = await currentUid();
      final snap = await _firestore.doc('creditLedgers/user_$uid').get();
      _balance = snap.exists ? CreditBalance.fromMap(snap.data() ?? const {}) : CreditBalance.empty;
    } catch (_) {
      // keep whatever we had
    }
  }

  Future<List<CreditTransaction>> recentTransactions({int limit = 25}) async {
    final uid = await currentUid();
    final q = await _firestore
        .collection('creditLedgers/user_$uid/transactions')
        .orderBy('at', descending: true)
        .limit(limit)
        .get();
    return [
      for (final d in q.docs)
        CreditTransaction.fromMap(d.data(), at: (d.data()['at'] is Timestamp) ? (d.data()['at'] as Timestamp).toDate() : null),
    ];
  }

  /// Asks the server to verify a Play purchase and add its credits. Throws
  /// [CreditRedeemException] with a teacher-readable message on refusal.
  Future<RedeemOutcome> redeemPurchase({required String productId, required String purchaseToken}) async {
    await AuthService.instance.ensureSignedIn();
    try {
      final result = await _functions
          .httpsCallable('redeemMarkingBundle', options: HttpsCallableOptions(timeout: const Duration(seconds: 60)))
          .call<Object?>({'productId': productId, 'purchaseToken': purchaseToken});
      final data = result.data;
      if (data is! Map) throw const CreditRedeemException('The server gave an unexpected reply.', retryable: true);
      final granted = data['creditsGranted'];
      final balance = data['balance'];
      return RedeemOutcome(
        creditsGranted: granted is num ? granted.toDouble() : 0,
        duplicate: data['duplicate'] == true,
        balance: balance is num ? balance.toDouble() : null,
      );
    } on FirebaseFunctionsException catch (e) {
      throw CreditRedeemException.fromCode(e.code, e.details, e.message);
    }
  }
}

class RedeemOutcome {
  final double creditsGranted;
  final bool duplicate;
  final double? balance;

  const RedeemOutcome({required this.creditsGranted, required this.duplicate, this.balance});
}

/// A refused or failed redemption. [retryable] means the purchase is still
/// good and should be tried again later (network trouble, verification not
/// ready); [needsSignIn] means the teacher must sign in first; neither means
/// the purchase can never be credited (e.g. it belongs to another account).
class CreditRedeemException implements Exception {
  final String message;
  final bool retryable;
  final bool needsSignIn;

  const CreditRedeemException(this.message, {this.retryable = false, this.needsSignIn = false});

  factory CreditRedeemException.fromCode(String code, Object? details, String? message) {
    final detailCode = details is Map ? details['code'] : null;
    if (detailCode == 'sign_in_required') {
      return CreditRedeemException(message ?? 'Please sign in before buying credits.', needsSignIn: true);
    }
    if (detailCode == 'verification_unavailable' || detailCode == 'purchase_pending' || code == 'unavailable') {
      return CreditRedeemException(message ?? 'Could not confirm the purchase yet. It will be retried.', retryable: true);
    }
    return CreditRedeemException(message ?? 'The purchase could not be credited.');
  }

  @override
  String toString() => message;
}
