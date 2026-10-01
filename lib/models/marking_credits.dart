/// Marking credits — the client's read-only view of the server-authoritative
/// credit system (Monetization, 2026-09-19). The truth lives in Firestore and
/// is changed ONLY by Cloud Functions; nothing here can grant, spend or price
/// anything. Everything below is for showing the teacher where they stand
/// and for a courtesy "you can't afford this" check before a network call.
///
/// The device date is used here for DISPLAY only (which per-page cost to
/// show, whether a new price is coming). The server decides the real price
/// from its own clock, so a wrong device date can never change what is
/// charged.
library;

/// Which of the three marking engines a call belongs to. (Named differently
/// from the screen-local `MarkingEngine` enum on purpose, so the two never
/// get confused.)
enum MarkingEngineKind {
  stable,
  concise,
  keyed;

  String get label => switch (this) {
        MarkingEngineKind.stable => 'Stable Marker',
        MarkingEngineKind.concise => 'Concise Marking',
        MarkingEngineKind.keyed => 'Key-based Marking',
      };
}

/// Teacher-readable name of an AI feature key (as used by the server's metering).
String featureLabel(String feature) => switch (feature) {
      'lessonPlan' => 'lesson plan',
      'requiredCoreTopics' => 'core-topic research',
      'schemeOfWork' => 'scheme of work',
      'teachingNotes' => 'set of teaching notes',
      'slideOutline' => 'slide outline',
      'freeTopicNotes' => 'set of topic notes',
      'transcription' => 'transcription',
      'markingKeyDerivation' => 'marking key',
      'homeAssignment' => 'home assignment',
      'minutes' => 'set of minutes',
      'timetable' => 'timetable',
      'timetableAssist' => 'timetable assist',
      _ => 'AI generation',
    };

/// 1 credit = 1000 units server-side, so a weight like 3.2 never drifts.
const int kUnitsPerCredit = 1000;

double unitsToCredits(num units) => units / kUnitsPerCredit;
int creditsToUnits(num credits) => (credits * kUnitsPerCredit).round();

/// Per-page credit cost of each engine.
class CreditWeights {
  final double stable;
  final double concise;
  final double keyed;

  const CreditWeights({required this.stable, required this.concise, required this.keyed});

  double of(MarkingEngineKind engine) => switch (engine) {
        MarkingEngineKind.stable => stable,
        MarkingEngineKind.concise => concise,
        MarkingEngineKind.keyed => keyed,
      };
}

class CreditWeightSet {
  /// The instant this set takes effect (the config's ISO-8601 offset time, as UTC).
  final DateTime effectiveFrom;
  final CreditWeights weights;

  const CreditWeightSet({required this.effectiveFrom, required this.weights});
}

/// One purchasable credit bundle — the credits amount and list price come
/// from the remote config, never from this file.
class BundleOffer {
  final String productId;
  final double credits;
  final double listAmount;
  final String currency;

  const BundleOffer({required this.productId, required this.credits, required this.listAmount, required this.currency});
}

class MarkingCreditsConfig {
  /// 'off' (no charging), 'shadow' (record only), or 'enforced' (real).
  final String mode;
  final double freeMonthlyCredits;
  final List<CreditWeightSet> weightSets;
  final String activeScenario;
  final Map<String, List<BundleOffer>?> scenarios;

  const MarkingCreditsConfig({
    required this.mode,
    required this.freeMonthlyCredits,
    required this.weightSets,
    required this.activeScenario,
    required this.scenarios,
  });

  bool get isEnforced => mode == 'enforced';

  /// The safe fallback when no config has been fetched (or it is unreadable).
  /// Mode 'off' — so a missing config can never start charging anyone. Values
  /// mirror the server's DEFAULT_MARKING_CREDITS_CONFIG.
  static final MarkingCreditsConfig defaults = MarkingCreditsConfig(
    mode: 'off',
    freeMonthlyCredits: 10,
    weightSets: [
      CreditWeightSet(
        effectiveFrom: DateTime.parse('2026-09-19T00:00:00+02:00').toUtc(),
        weights: const CreditWeights(stable: 1, concise: 3.2, keyed: 3.3),
      ),
      CreditWeightSet(
        effectiveFrom: DateTime.parse('2027-01-01T00:00:00+02:00').toUtc(),
        weights: const CreditWeights(stable: 1, concise: 6.4, keyed: 6.5),
      ),
    ],
    activeScenario: 'scenario1',
    scenarios: const {
      'scenario1': [
        BundleOffer(productId: 'marking_bundle_k50', credits: 87, listAmount: 50, currency: 'ZMW'),
        BundleOffer(productId: 'marking_bundle_k100', credits: 178, listAmount: 100, currency: 'ZMW'),
        BundleOffer(productId: 'marking_bundle_k150', credits: 268, listAmount: 150, currency: 'ZMW'),
      ],
      'scenario2': null,
    },
  );

  /// Defensive parse of the Firestore document — anything invalid falls back
  /// to the default for that part, exactly like the server does.
  static MarkingCreditsConfig fromMap(Object? raw) {
    if (raw is! Map) return defaults;
    var mode = defaults.mode;
    final rawMode = raw['mode'];
    if (rawMode == 'off' || rawMode == 'shadow' || rawMode == 'enforced') mode = rawMode as String;

    var free = defaults.freeMonthlyCredits;
    final rawFree = raw['freeMonthlyCredits'];
    if (rawFree is num && rawFree.isFinite && rawFree >= 0) free = rawFree.toDouble();

    var sets = defaults.weightSets;
    final rawSets = raw['weightSets'];
    if (rawSets is List) {
      final parsed = <CreditWeightSet>[];
      for (final s in rawSets) {
        if (s is! Map) continue;
        final from = s['effectiveFrom'] is String ? DateTime.tryParse(s['effectiveFrom'] as String) : null;
        final w = s['weights'];
        if (from == null || w is! Map) continue;
        double? pos(Object? v) => (v is num && v.isFinite && v > 0) ? v.toDouble() : null;
        final stable = pos(w['stable']), concise = pos(w['concise']), keyed = pos(w['keyed']);
        if (stable == null || concise == null || keyed == null) continue;
        parsed.add(CreditWeightSet(
          effectiveFrom: from.toUtc(),
          weights: CreditWeights(stable: stable, concise: concise, keyed: keyed),
        ));
      }
      if (parsed.isNotEmpty) sets = parsed;
    }
    sets = [...sets]..sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom));

    var activeScenario = defaults.activeScenario;
    var scenarios = defaults.scenarios;
    final b = raw['bundles'];
    if (b is Map) {
      if (b['activeScenario'] is String && (b['activeScenario'] as String).isNotEmpty) {
        activeScenario = b['activeScenario'] as String;
      }
      final rawScenarios = b['scenarios'];
      if (rawScenarios is Map) {
        final parsed = <String, List<BundleOffer>?>{};
        rawScenarios.forEach((name, defs) {
          if (name is! String) return;
          if (defs == null) {
            parsed[name] = null;
            return;
          }
          if (defs is! Map) return;
          final offers = <BundleOffer>[];
          defs.forEach((productId, d) {
            if (productId is! String || d is! Map) return;
            final credits = d['credits'];
            final price = d['listPrice'];
            if (credits is num && credits > 0 && price is Map && price['amount'] is num && (price['amount'] as num) > 0 && price['currency'] is String) {
              offers.add(BundleOffer(
                productId: productId,
                credits: credits.toDouble(),
                listAmount: (price['amount'] as num).toDouble(),
                currency: price['currency'] as String,
              ));
            }
          });
          parsed[name] = offers;
        });
        if (parsed.isNotEmpty) scenarios = parsed;
      }
    }

    return MarkingCreditsConfig(
      mode: mode,
      freeMonthlyCredits: free,
      weightSets: sets,
      activeScenario: activeScenario,
      scenarios: scenarios,
    );
  }

  /// The weight set in force at [now] (device clock — DISPLAY ONLY): the
  /// latest whose date has passed, else the earliest.
  CreditWeightSet weightSetAt(DateTime now) {
    var chosen = weightSets.first;
    for (final s in weightSets) {
      if (!s.effectiveFrom.isAfter(now.toUtc())) chosen = s;
    }
    return chosen;
  }

  /// The next weight set that has not taken effect yet, if any — so the app can warn of a coming price change.
  CreditWeightSet? upcomingWeightSet(DateTime now) {
    for (final s in weightSets) {
      if (s.effectiveFrom.isAfter(now.toUtc())) return s;
    }
    return null;
  }

  /// Bundles for sale now: the active scenario, falling back to scenario1 when it isn't defined.
  List<BundleOffer> get activeBundles => scenarios[activeScenario] ?? scenarios['scenario1'] ?? const [];

  /// Credits this many pages will cost on [engine] at [now]'s prices (via
  /// integer units, matching the server's rounding).
  double costFor(MarkingEngineKind engine, int pages, DateTime now) {
    return unitsToCredits(creditsToUnits(weightSetAt(now).weights.of(engine) * pages));
  }
}

/// Zambia (CAT) is UTC+2 all year, no daylight saving — same month key the server uses.
String periodKeyCat(DateTime now) {
  final d = now.toUtc().add(const Duration(hours: 2));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

/// The teacher's balance, as stored on their ledger.
class CreditBalance {
  final double freeCredits;
  final double purchasedCredits;
  final String? freePeriod;

  const CreditBalance({required this.freeCredits, required this.purchasedCredits, this.freePeriod});

  static const CreditBalance empty = CreditBalance(freeCredits: 0, purchasedCredits: 0);

  factory CreditBalance.fromMap(Map<String, Object?> data) {
    double units(Object? v) => v is num && v.isFinite ? unitsToCredits(v) : 0;
    return CreditBalance(
      freeCredits: units(data['freeUnits']),
      purchasedCredits: units(data['purchasedUnits']),
      freePeriod: data['freePeriod'] is String ? data['freePeriod'] as String : null,
    );
  }

  /// What the teacher can actually spend right now. A new month wipes unused
  /// free credits and grants a fresh allowance (the server does that on the
  /// next marking; this mirrors it so the display isn't stale in the meantime).
  double spendable(MarkingCreditsConfig config, DateTime now) {
    final freeNow = freePeriod == periodKeyCat(now) ? freeCredits : config.freeMonthlyCredits;
    return purchasedCredits + freeNow;
  }

  double freeAvailable(MarkingCreditsConfig config, DateTime now) =>
      freePeriod == periodKeyCat(now) ? freeCredits : config.freeMonthlyCredits;
}

/// One line of the teacher's credit history.
class CreditTransaction {
  final String type; // free_grant | spend | purchase | shadow_spend
  final double credits; // signed: negative = spent
  final DateTime? at;
  final String? productId;
  final String? engine;
  final int? pages;

  /// Set for a non-marking AI generation (e.g. 'lessonPlan').
  final String? feature;

  const CreditTransaction({required this.type, required this.credits, this.at, this.productId, this.engine, this.pages, this.feature});

  factory CreditTransaction.fromMap(Map<String, Object?> data, {DateTime? at}) => CreditTransaction(
        type: data['type'] is String ? data['type'] as String : 'unknown',
        credits: data['units'] is num ? unitsToCredits(data['units'] as num) : 0,
        at: at,
        productId: data['productId'] is String ? data['productId'] as String : null,
        engine: data['engine'] is String ? data['engine'] as String : null,
        pages: data['pages'] is num ? (data['pages'] as num).toInt() : null,
        feature: data['feature'] is String ? data['feature'] as String : null,
      );

  String get description => switch (type) {
        'free_grant' => 'Monthly free credits',
        'spend' when feature != null => _capitalize(featureLabel(feature!)),
        'shadow_spend' when feature != null => '${_capitalize(featureLabel(feature!))} (trial run, not charged)',
        'ad_pass_spend' => '${_capitalize(featureLabel(feature ?? ''))} (paid with an ad)',
        'spend' => 'Marking${engine != null ? ' (${_engineLabel(engine!)})' : ''}${pages != null ? ', $pages page${pages == 1 ? '' : 's'}' : ''}',
        'purchase' => 'Bundle purchased',
        'shadow_spend' => 'Marking (trial run, not charged)',
        _ => 'Credit change',
      };

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _engineLabel(String e) => switch (e) {
        'stable' => 'Stable',
        'concise' => 'Concise',
        'keyed' => 'Key-based',
        _ => e,
      };
}

/// Thrown when the server refuses a marking call because the balance can't
/// cover it (nothing was charged and no AI call was made). Carries the
/// numbers so the dialog can say exactly what is missing.
class InsufficientCreditsException implements Exception {
  final double requiredCredits;
  final double availableCredits;
  final String message;

  /// Which AI feature was refused (e.g. 'lessonPlan'); null for marking.
  final String? feature;

  /// Whether watching a rewarded ad could pay for this one use instead
  /// (the server has ad passes switched on). Never true for marking.
  final bool adPassEligible;

  const InsufficientCreditsException({
    required this.requiredCredits,
    required this.availableCredits,
    required this.message,
    this.feature,
    this.adPassEligible = false,
  });

  @override
  String toString() => message;
}

/// What the server reports back after charging a script (present only in
/// shadow/enforced mode).
class CreditsCharged {
  final bool duplicate;
  final double charged;
  final double? balance;

  const CreditsCharged({required this.duplicate, required this.charged, this.balance});

  static CreditsCharged? fromResponse(Object? raw) {
    if (raw is! Map) return null;
    final charged = raw['charged'];
    if (charged is! num) return null;
    final balance = raw['balance'];
    return CreditsCharged(
      duplicate: raw['duplicate'] == true,
      charged: charged.toDouble(),
      balance: balance is num ? balance.toDouble() : null,
    );
  }
}
