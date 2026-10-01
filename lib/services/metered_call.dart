import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';

import '../models/marking_credits.dart';
import 'marking_credits_service.dart';

/// Tells the app's root that an AI feature was just refused for lack of
/// credits, so ONE dialog ("Out of credits — get more / watch an ad") can be
/// shown from anywhere — without every screen having to handle it. (The
/// calling service still receives the typed exception, so it can stop cleanly;
/// the dialog is only the explanation and the way forward.)
class OutOfCreditsNotifier {
  OutOfCreditsNotifier._();
  static final OutOfCreditsNotifier instance = OutOfCreditsNotifier._();

  final StreamController<InsufficientCreditsException> _controller = StreamController<InsufficientCreditsException>.broadcast();
  DateTime? _lastAt;

  Stream<InsufficientCreditsException> get stream => _controller.stream;

  /// A service that retries, or two calls in quick succession, must not stack dialogs.
  void notify(InsufficientCreditsException reason, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final last = _lastAt;
    // A negative gap means the device clock went backwards — never let that silence the dialog.
    if (last != null && !t.difference(last).isNegative && t.difference(last) < const Duration(seconds: 8)) return;
    _lastAt = t;
    _controller.add(reason);
  }
}

/// The teacher's one-shot choice to pay for the NEXT generation with an ad pass
/// rather than credits (set from the credits screen / out-of-credits dialog).
class AdPassPreference {
  AdPassPreference._();
  static final AdPassPreference instance = AdPassPreference._();

  bool _preferAd = false;

  void preferAdForNextUse() => _preferAd = true;

  /// True once, then resets — a pass pays for exactly one generation.
  bool takePreferAd() {
    final v = _preferAd;
    _preferAd = false;
    return v;
  }
}

/// Adds the fields the server's metering needs to a call's payload: a fresh
/// request id (so one generation is never charged twice) and, when the
/// teacher chose it, `payWith: 'ad'`. Non-map payloads pass through untouched.
Object? withMeteringFields(Object? parameters, {required String requestId, bool payWithAd = false}) {
  if (parameters == null) {
    return {'requestId': requestId, if (payWithAd) 'payWith': 'ad'};
  }
  if (parameters is Map) {
    return {
      ...parameters,
      'requestId': requestId,
      if (payWithAd) 'payWith': 'ad',
    };
  }
  return parameters;
}

/// A drop-in replacement for [HttpsCallable] for the AI features that cost
/// credits. It sends a request id, converts the server's "not enough credits"
/// refusal into an [InsufficientCreditsException] (and tells the app root),
/// and keeps the cached balance fresh from the reply. Everything else — the
/// payload, the timeout options, every other error — is unchanged.
class MeteredCallable {
  /// [invoke] is the real call (normally `httpsCallable(...).call`); taking it
  /// as a function keeps the wrapper testable without Firebase.
  MeteredCallable(this._invoke, {this.notifyOnOutOfCredits = true});

  MeteredCallable.wrap(HttpsCallable callable, {bool notify = true}) : this(callable.call, notifyOnOutOfCredits: notify);

  final Future<HttpsCallableResult<T>> Function<T>([dynamic parameters]) _invoke;

  /// Whether a refusal should raise the app-wide dialog (default) or stay quiet.
  final bool notifyOnOutOfCredits;

  Future<HttpsCallableResult<T>> call<T>([Object? parameters]) async {
    final data = withMeteringFields(
      parameters,
      requestId: MarkingRequestIds.fresh(),
      payWithAd: AdPassPreference.instance.takePreferAd(),
    );
    try {
      final result = await _invoke<T>(data);
      final body = result.data;
      if (body is Map) {
        final charged = CreditsCharged.fromResponse(body['credits']);
        if (charged?.balance case final balance?) MarkingCreditsService.instance.noteSpendableBalance(balance);
      }
      return result;
    } on FirebaseFunctionsException catch (e) {
      final noCredits = insufficientCreditsFromException(e);
      if (noCredits != null) {
        if (notifyOnOutOfCredits) OutOfCreditsNotifier.instance.notify(noCredits);
        throw noCredits;
      }
      rethrow;
    }
  }
}

/// `functions.httpsCallable(name, options: ...)`, metered.
MeteredCallable meteredCallable(FirebaseFunctions functions, String name, {HttpsCallableOptions? options, bool notify = true}) =>
    MeteredCallable.wrap(functions.httpsCallable(name, options: options), notify: notify);
