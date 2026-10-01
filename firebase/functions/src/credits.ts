// Marking credits — the server-authoritative ledger behind AI marking
// (Monetization Stages 1-3, 2026-09-19).
//
// WHY SERVER-SIDE: the app's older free-script counter lived in the phone's
// SharedPreferences, so anyone could reset it (clear app data) — fine while
// nothing was for sale, useless the moment credits cost real money. Every
// balance change therefore happens here, in Firestore transactions run with
// the Admin SDK; clients may only READ their own ledger (see
// firestore.rules). Nothing in this file trusts a client-reported date,
// price, weight or balance.
//
// UNITS: money-adjacent maths is done in integer "units" (1 credit = 1000
// units) so weights like 3.2 credits/page never accumulate floating-point
// drift across thousands of pages.
//
// Pure functions (config parsing, weight selection, free-allowance roll,
// spend order) are separate from the Firestore functions on purpose — the
// pure part is unit-tested directly, the Firestore part against the local
// emulator (credits.int.test.ts).
import { createHash } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

export type MarkingEngine = "stable" | "concise" | "keyed";
export type CreditsMode = "off" | "shadow" | "enforced";

export const UNITS_PER_CREDIT = 1000;
export const toUnits = (credits: number): number => Math.round(credits * UNITS_PER_CREDIT);
export const fromUnits = (units: number): number => units / UNITS_PER_CREDIT;

export interface WeightSet {
  /** ISO-8601 with an explicit offset, e.g. "2027-01-01T00:00:00+02:00". */
  effectiveFrom: string;
  /** Credits charged per marked PAGE, per engine. */
  weights: Record<MarkingEngine, number>;
  /**
   * Credits charged per successful use of each NON-marking AI feature
   * (lesson plan, scheme of work, transcription, ...). 0 = not charged but
   * still usage-logged. Effective-dated with the marking weights because the
   * same Gemini price change (1 Jan 2027) affects both.
   */
  features: Record<string, number>;
}

/**
 * Google's purchase lookup returns NO price, so the price paid is read from the
 * separate Orders API. A client can't influence what Google charges (it sends no
 * price), so a mismatch means a misconfigured Play Console price, a promotion or
 * a bug - not tampering - and is treated as something to investigate.
 *  - "hold": a purchase clearly UNDER the bundle's price (same currency) is not
 *    credited and not acknowledged, so Google refunds it automatically within 3 days;
 *    an over-payment is credited and flagged.
 *  - "flag": credited either way, flagged for investigation.
 *  - "off": no price check.
 */
export interface PurchasePolicy {
  priceCheck: "hold" | "flag" | "off";
  /** Allowed difference either way, percent (rounding / tax presentation). */
  tolerancePercent: number;
}

/**
 * Refund abuse (buy, spend, refund, repeat). Owner's brief asked for the
 * spent-but-refunded case to be decided; the decision is: credits still unspent
 * are taken back; the spent part becomes a DEBT the next purchase repays first
 * (balance never goes negative); and `blockAfterRefunds` refunds inside
 * `windowDays` pause the account's purchases until the owner clears it.
 */
export interface RefundPolicy {
  blockAfterRefunds: number;
  windowDays: number;
}

/** Ad-watching as an alternative way to pay for ONE generation (never for marking). */
export interface AdPassConfig {
  /** Off until a real rewarded-ad SDK + AdMob server-side verification are live. */
  enabled: boolean;
  /** Most passes one teacher can earn per Zambian calendar day. */
  perDayCap: number;
  /** How long an earned, unused pass stays valid. */
  ttlHours: number;
}

export interface BundleDef {
  credits: number;
  listPrice: { amount: number; currency: string };
}

export interface MarkingCreditsConfig {
  /** off = no checks, no deductions (today's behaviour); shadow = record what WOULD be charged but never block or change a balance; enforced = real. */
  mode: CreditsMode;
  /**
   * Same three states, for the non-marking AI features. Separate from [mode]
   * so marking can go live first. Defaults to "off" whatever [mode] says.
   */
  featuresMode: CreditsMode;
  adPasses: AdPassConfig;
  /**
   * Real AI cost (USD) a subscribed (Gold/Institutional) SCHOOL's usage of a
   * feature group is INCLUDED for, per Zambian calendar month. Below it a use
   * isn't charged; once the school's measured spend passes it, further uses are
   * charged in credits as normal. Keyed by allowance group (currently just
   * "timetable"). Measured from the real token log, not estimated.
   */
  schoolAllowancesUsd: Record<string, number>;
  /** How a purchase whose price Google reports doesn't match the bundle's price is treated. */
  purchasePolicy: PurchasePolicy;
  /** What repeated refunds do to an account. */
  refundPolicy: RefundPolicy;
  /** Free credits granted each calendar month (Zambia time). Does not roll over. */
  freeMonthlyCredits: number;
  weightSets: WeightSet[];
  bundles: {
    activeScenario: string;
    /** productId -> definition, per scenario. A scenario may be null (not defined yet). */
    scenarios: Record<string, Record<string, BundleDef> | null>;
  };
}

// The defaults double as the safe fallback when the remote config document
// is missing or malformed — same values as the seed document in
// firebase/seed/marking_credits_config.json. Remote config always wins.
// STARTING ESTIMATES, not measurements. 1 credit is priced at ~$0.0026 of AI
// cost (the marking weights were built that way), and each figure below is a
// rough token estimate at gemini-3.6-flash 2026 prices ($0.75 in / $3.75 out
// per 1M, thinking billed as output). The feature usage log records the real
// cost of every call, and the owner finance screen shows measured cost per use
// against these, so they should be corrected from data, not trusted.
export const DEFAULT_FEATURE_WEIGHTS_2026: Record<string, number> = {
  lessonPlan: 10, // ~3k in, ~4k out + ~2k thinking  ≈ $0.025
  requiredCoreTopics: 20, // two grounded (web-search) calls  ≈ $0.05
  schemeOfWork: 10, // one batched call for the whole scheme  ≈ $0.025
  teachingNotes: 8, // ≈ $0.018
  slideOutline: 6, // ≈ $0.015
  freeTopicNotes: 8, // ≈ $0.02
  transcription: 4, // per call, image input  ≈ $0.01
  markingKeyDerivation: 8, // ≈ $0.02
  homeAssignment: 8, // ≈ $0.02
  minutes: 8, // ≈ $0.02
  timetable: 2, // independent-timetable build: computed, not AI — a flat charge
  timetableAssist: 3, // explain conflicts / read a constraint / read a photo
  structurePreview: 3, // Marking Reliability Stage 1: cover-page-only structure read, up to 3 images, small output
  // Tiny utility calls: logged, not charged.
  voiceCommand: 0,
  topicSearch: 0,
  candidateName: 0,
};
// From 1 Jan 2027 gemini-3.6-flash doubles in price, so its features double;
// the computed timetable does not, and timetableAssist mixes one Flash-Lite call.
export const DEFAULT_FEATURE_WEIGHTS_2027: Record<string, number> = {
  ...Object.fromEntries(Object.entries(DEFAULT_FEATURE_WEIGHTS_2026).map(([k, v]) => [k, v * 2])),
  timetable: 2,
  timetableAssist: 5,
};

export const DEFAULT_AD_PASSES: AdPassConfig = { enabled: false, perDayCap: 5, ttlHours: 24 };
export const DEFAULT_PURCHASE_POLICY: PurchasePolicy = { priceCheck: "hold", tolerancePercent: 2 };
export const DEFAULT_REFUND_POLICY: RefundPolicy = { blockAfterRefunds: 2, windowDays: 90 };

// Owner's decision (2026-09-19): Gold and Institutional schools get $1 of real AI cost a
// month included for timetable work; beyond that they are charged.
export const DEFAULT_SCHOOL_ALLOWANCES_USD: Record<string, number> = { timetable: 1 };

export const DEFAULT_MARKING_CREDITS_CONFIG: MarkingCreditsConfig = {
  mode: "off",
  featuresMode: "off",
  adPasses: DEFAULT_AD_PASSES,
  schoolAllowancesUsd: DEFAULT_SCHOOL_ALLOWANCES_USD,
  purchasePolicy: DEFAULT_PURCHASE_POLICY,
  refundPolicy: DEFAULT_REFUND_POLICY,
  // 10 credits/month (owner's decision, 2026-09-19 — "more sustainable" than 20):
  // 2.5 four-page scripts on Stable, or ~3 Concise pages. About $0.026 of AI cost
  // per teacher per month at the model's Base estimate.
  freeMonthlyCredits: 10,
  weightSets: [
    { effectiveFrom: "2026-09-19T00:00:00+02:00", weights: { stable: 1, concise: 3.2, keyed: 3.3 }, features: DEFAULT_FEATURE_WEIGHTS_2026 },
    { effectiveFrom: "2027-01-01T00:00:00+02:00", weights: { stable: 1, concise: 6.4, keyed: 6.5 }, features: DEFAULT_FEATURE_WEIGHTS_2027 },
  ],
  bundles: {
    activeScenario: "scenario1",
    scenarios: {
      scenario1: {
        marking_bundle_k50: { credits: 87, listPrice: { amount: 50, currency: "ZMW" } },
        marking_bundle_k100: { credits: 178, listPrice: { amount: 100, currency: "ZMW" } },
        marking_bundle_k150: { credits: 268, listPrice: { amount: 150, currency: "ZMW" } },
      },
      // Sizing for after the VAT threshold is crossed — not supplied yet.
      scenario2: null,
    },
  },
};

const ENGINES: MarkingEngine[] = ["stable", "concise", "keyed"];
const isPosNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v > 0;

/** Defensive parse of the remote config document — anything invalid falls back to the default for that part. */
export function parseMarkingCreditsConfig(raw: unknown): MarkingCreditsConfig {
  const cfg: MarkingCreditsConfig = JSON.parse(JSON.stringify(DEFAULT_MARKING_CREDITS_CONFIG));
  if (!raw || typeof raw !== "object") return cfg;
  const r = raw as Record<string, unknown>;

  if (r.mode === "off" || r.mode === "shadow" || r.mode === "enforced") cfg.mode = r.mode;
  if (r.featuresMode === "off" || r.featuresMode === "shadow" || r.featuresMode === "enforced") cfg.featuresMode = r.featuresMode;
  if (r.schoolAllowancesUsd && typeof r.schoolAllowancesUsd === "object") {
    const allowances: Record<string, number> = { ...DEFAULT_SCHOOL_ALLOWANCES_USD };
    for (const [k, v] of Object.entries(r.schoolAllowancesUsd as Record<string, unknown>)) {
      if (typeof v === "number" && Number.isFinite(v) && v >= 0) allowances[k] = v;
    }
    cfg.schoolAllowancesUsd = allowances;
  }
  if (r.purchasePolicy && typeof r.purchasePolicy === "object") {
    const pp = r.purchasePolicy as Record<string, unknown>;
    cfg.purchasePolicy = {
      priceCheck: pp.priceCheck === "flag" || pp.priceCheck === "off" || pp.priceCheck === "hold" ? pp.priceCheck : DEFAULT_PURCHASE_POLICY.priceCheck,
      tolerancePercent: typeof pp.tolerancePercent === "number" && Number.isFinite(pp.tolerancePercent) && pp.tolerancePercent >= 0 ? pp.tolerancePercent : DEFAULT_PURCHASE_POLICY.tolerancePercent,
    };
  }
  if (r.refundPolicy && typeof r.refundPolicy === "object") {
    const rp = r.refundPolicy as Record<string, unknown>;
    cfg.refundPolicy = {
      blockAfterRefunds: isPosNum(rp.blockAfterRefunds) ? Math.floor(rp.blockAfterRefunds) : DEFAULT_REFUND_POLICY.blockAfterRefunds,
      windowDays: isPosNum(rp.windowDays) ? rp.windowDays : DEFAULT_REFUND_POLICY.windowDays,
    };
  }
  if (r.adPasses && typeof r.adPasses === "object") {
    const a = r.adPasses as Record<string, unknown>;
    cfg.adPasses = {
      enabled: a.enabled === true,
      perDayCap: isPosNum(a.perDayCap) ? Math.floor(a.perDayCap) : DEFAULT_AD_PASSES.perDayCap,
      ttlHours: isPosNum(a.ttlHours) ? a.ttlHours : DEFAULT_AD_PASSES.ttlHours,
    };
  }
  if (typeof r.freeMonthlyCredits === "number" && Number.isFinite(r.freeMonthlyCredits) && r.freeMonthlyCredits >= 0) {
    cfg.freeMonthlyCredits = r.freeMonthlyCredits;
  }

  if (Array.isArray(r.weightSets)) {
    const sets: WeightSet[] = [];
    for (const s of r.weightSets) {
      if (!s || typeof s !== "object") continue;
      const { effectiveFrom, weights } = s as { effectiveFrom?: unknown; weights?: Record<string, unknown> };
      if (typeof effectiveFrom !== "string" || Number.isNaN(Date.parse(effectiveFrom))) continue;
      if (!weights || !ENGINES.every((e) => isPosNum(weights[e]))) continue;
      // Feature costs: start from the defaults for that era, then apply any valid override (>= 0).
      const era = Date.parse(effectiveFrom) >= Date.parse("2027-01-01T00:00:00+02:00") ? DEFAULT_FEATURE_WEIGHTS_2027 : DEFAULT_FEATURE_WEIGHTS_2026;
      const features: Record<string, number> = { ...era };
      const rawFeatures = (s as { features?: unknown }).features;
      if (rawFeatures && typeof rawFeatures === "object") {
        for (const [k, v] of Object.entries(rawFeatures as Record<string, unknown>)) {
          if (typeof v === "number" && Number.isFinite(v) && v >= 0) features[k] = v;
        }
      }
      sets.push({
        effectiveFrom,
        weights: { stable: weights.stable as number, concise: weights.concise as number, keyed: weights.keyed as number },
        features,
      });
    }
    if (sets.length > 0) cfg.weightSets = sets;
  }
  cfg.weightSets.sort((a, b) => Date.parse(a.effectiveFrom) - Date.parse(b.effectiveFrom));

  const b = r.bundles as { activeScenario?: unknown; scenarios?: Record<string, unknown> } | undefined;
  if (b && typeof b === "object") {
    if (typeof b.activeScenario === "string" && b.activeScenario) cfg.bundles.activeScenario = b.activeScenario;
    if (b.scenarios && typeof b.scenarios === "object") {
      const parsed: Record<string, Record<string, BundleDef> | null> = {};
      for (const [name, defs] of Object.entries(b.scenarios)) {
        if (defs === null) {
          parsed[name] = null;
          continue;
        }
        if (!defs || typeof defs !== "object") continue;
        const products: Record<string, BundleDef> = {};
        for (const [productId, d] of Object.entries(defs as Record<string, unknown>)) {
          const def = d as { credits?: unknown; listPrice?: { amount?: unknown; currency?: unknown } };
          if (isPosNum(def?.credits) && isPosNum(def?.listPrice?.amount) && typeof def?.listPrice?.currency === "string") {
            products[productId] = {
              credits: def.credits,
              listPrice: { amount: def.listPrice.amount as number, currency: def.listPrice.currency as string },
            };
          }
        }
        parsed[name] = products;
      }
      if (Object.keys(parsed).length > 0) cfg.bundles.scenarios = parsed;
    }
  }
  return cfg;
}

/** The weight set in force at [nowMs] — the latest whose effectiveFrom has passed, else the earliest. SERVER TIME ONLY. */
export function selectWeightSet(cfg: MarkingCreditsConfig, nowMs: number): WeightSet {
  let chosen = cfg.weightSets[0];
  for (const s of cfg.weightSets) {
    if (Date.parse(s.effectiveFrom) <= nowMs) chosen = s;
  }
  return chosen;
}

/** Credits one successful use of [feature] costs at [nowMs]; unknown features are 0 (not charged). */
export function featureWeight(cfg: MarkingCreditsConfig, nowMs: number, feature: string): number {
  return selectWeightSet(cfg, nowMs).features[feature] ?? 0;
}

/** Bundles sellable right now: the active scenario, falling back to scenario1 if that one isn't defined. */
export function activeBundles(cfg: MarkingCreditsConfig): Record<string, BundleDef> {
  return cfg.bundles.scenarios[cfg.bundles.activeScenario] ?? cfg.bundles.scenarios.scenario1 ?? {};
}

/** Which engine a marking request belongs to (the three share one Cloud Function). */
export function detectEngine(opts: { lightweight?: boolean; hasMarkingKey?: boolean }): MarkingEngine {
  if (opts.lightweight === true) return "stable";
  return opts.hasMarkingKey ? "keyed" : "concise";
}

/** Units to charge for marking [pages] pages at [weight] credits per page. */
export const creditUnitsForCall = (weight: number, pages: number): number => toUnits(weight * pages);

const CAT_OFFSET_MS = 2 * 60 * 60 * 1000; // Zambia (CAT) is UTC+2 all year, no daylight saving.
/** Calendar-month key in Zambia time, e.g. "2027-01" — the free allowance resets when this changes. */
export function periodKeyCAT(nowMs: number): string {
  const d = new Date(nowMs + CAT_OFFSET_MS);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

export interface LedgerState {
  purchasedUnits: number;
  freeUnits: number;
  freePeriod: string | null;
}
export const emptyLedger = (): LedgerState => ({ purchasedUnits: 0, freeUnits: 0, freePeriod: null });
export const availableUnits = (s: LedgerState): number => s.purchasedUnits + s.freeUnits;

/** A new month wipes any unused free credits and grants a fresh allowance — no roll-over, by design. */
export function rollFreeAllowance(
  state: LedgerState,
  cfg: MarkingCreditsConfig,
  nowMs: number
): { state: LedgerState; granted: number; expired: number } {
  const period = periodKeyCAT(nowMs);
  if (state.freePeriod === period) return { state, granted: 0, expired: 0 };
  const granted = toUnits(cfg.freeMonthlyCredits);
  return { state: { ...state, freeUnits: granted, freePeriod: period }, granted, expired: state.freeUnits };
}

/** Free credits are spent before purchased ones (they expire; purchased don't). A shortfall means the balance couldn't cover it. */
export function applySpend(
  state: LedgerState,
  units: number
): { state: LedgerState; fromFree: number; fromPurchased: number; shortfall: number } {
  const fromFree = Math.min(state.freeUnits, units);
  const remaining = units - fromFree;
  const fromPurchased = Math.min(state.purchasedUnits, remaining);
  return {
    state: { ...state, freeUnits: state.freeUnits - fromFree, purchasedUnits: state.purchasedUnits - fromPurchased },
    fromFree,
    fromPurchased,
    shortfall: remaining - fromPurchased,
  };
}

export const userOwnerKey = (uid: string): string => `user_${uid}`;
// Request ids come from the client — hash them so they're always a safe Firestore document id.
const safeId = (s: string): string => createHash("sha256").update(s).digest("hex").slice(0, 40);

function readLedger(data: FirebaseFirestore.DocumentData | undefined): LedgerState {
  if (!data) return emptyLedger();
  return {
    purchasedUnits: Number.isFinite(data.purchasedUnits) ? data.purchasedUnits : 0,
    freeUnits: Number.isFinite(data.freeUnits) ? data.freeUnits : 0,
    freePeriod: typeof data.freePeriod === "string" ? data.freePeriod : null,
  };
}

/** Read-only affordability check, run BEFORE the (paid) AI call. Only bites in "enforced" mode. */
export async function checkCanAfford(
  db: Firestore,
  ownerKey: string,
  cfg: MarkingCreditsConfig,
  engine: MarkingEngine,
  pages: number,
  nowMs: number
): Promise<{ ok: boolean; needUnits: number; availableUnits: number }> {
  const needUnits = creditUnitsForCall(selectWeightSet(cfg, nowMs).weights[engine], pages);
  if (cfg.mode !== "enforced") return { ok: true, needUnits, availableUnits: 0 };
  const snap = await db.collection("creditLedgers").doc(ownerKey).get();
  const rolled = rollFreeAllowance(readLedger(snap.data()), cfg, nowMs).state; // virtual — nothing is written
  const avail = availableUnits(rolled);
  return { ok: avail >= needUnits, needUnits, availableUnits: avail };
}

export interface ChargeArgs {
  ownerKey: string;
  ownerId: string;
  ownerType: "user" | "school";
  engine: MarkingEngine;
  pages: number;
  /** One id per user-initiated marking action, REUSED across automatic retries, so a script is never charged twice. */
  requestId?: string;
  cfg: MarkingCreditsConfig;
  nowMs: number;
  fn: string;
}

export interface ChargeResult {
  mode: CreditsMode;
  charged: boolean;
  duplicate: boolean;
  units: number;
  weight: number;
  shortfallUnits: number;
  freeUnitsAfter: number;
  purchasedUnitsAfter: number;
}

/**
 * Deduct credits for ONE successfully marked script. Called only after a
 * valid, readable result exists — never for a failed/unreadable attempt —
 * and only once, however many internal retries it took to get there.
 * (Exactly-once is enforced by [args.requestId]: a repeat of the same id is
 * a no-op.)
 */
export async function chargeSuccessfulMarking(db: Firestore, a: ChargeArgs): Promise<ChargeResult> {
  const weight = selectWeightSet(a.cfg, a.nowMs).weights[a.engine];
  const units = creditUnitsForCall(weight, a.pages);
  const noop: ChargeResult = {
    mode: a.cfg.mode, charged: false, duplicate: false, units, weight, shortfallUnits: 0, freeUnitsAfter: 0, purchasedUnitsAfter: 0,
  };
  if (a.cfg.mode === "off" || units <= 0) return noop;

  const ledgerRef = db.collection("creditLedgers").doc(a.ownerKey);
  const chargeRef = a.requestId ? ledgerRef.collection("charges").doc(safeId(a.requestId)) : undefined;
  const at = Timestamp.fromMillis(a.nowMs);
  const detail = { engine: a.engine, pages: a.pages, weight, fn: a.fn, requestId: a.requestId ?? null, at };

  return db.runTransaction(async (tx) => {
    const ledgerSnap = await tx.get(ledgerRef);
    const chargeSnap = chargeRef ? await tx.get(chargeRef) : undefined;
    const existing = readLedger(ledgerSnap.data());

    if (chargeSnap?.exists) {
      return { ...noop, duplicate: true, freeUnitsAfter: existing.freeUnits, purchasedUnitsAfter: existing.purchasedUnits };
    }

    // Shadow mode: record what WOULD have been charged, change nothing else.
    if (a.cfg.mode === "shadow") {
      tx.set(ledgerRef.collection("transactions").doc(), { type: "shadow_spend", units: -units, mode: "shadow", ...detail });
      if (chargeRef) tx.set(chargeRef, { units, mode: "shadow", at });
      return { ...noop, freeUnitsAfter: existing.freeUnits, purchasedUnitsAfter: existing.purchasedUnits };
    }

    // Enforced: roll the monthly allowance, then spend free-before-purchased.
    const roll = rollFreeAllowance(existing, a.cfg, a.nowMs);
    if (roll.granted > 0 || roll.expired > 0) {
      tx.set(ledgerRef.collection("transactions").doc(), {
        type: "free_grant", units: roll.granted, expiredUnits: roll.expired, period: roll.state.freePeriod, at,
      });
    }
    const spend = applySpend(roll.state, units);
    tx.set(
      ledgerRef,
      {
        ownerType: a.ownerType,
        ownerId: a.ownerId,
        purchasedUnits: spend.state.purchasedUnits,
        freeUnits: spend.state.freeUnits,
        freePeriod: spend.state.freePeriod,
        updatedAt: at,
        ...(ledgerSnap.exists ? {} : { createdAt: at }),
      },
      { merge: true }
    );
    const charged = units - spend.shortfall;
    tx.set(ledgerRef.collection("transactions").doc(), {
      type: "spend", units: -charged, shortfallUnits: spend.shortfall, fromFreeUnits: spend.fromFree,
      fromPurchasedUnits: spend.fromPurchased, freeAfter: spend.state.freeUnits, purchasedAfter: spend.state.purchasedUnits,
      mode: "enforced", ...detail,
    });
    if (chargeRef) tx.set(chargeRef, { units: charged, mode: "enforced", at });
    return {
      ...noop, charged: true, units: charged, shortfallUnits: spend.shortfall,
      freeUnitsAfter: spend.state.freeUnits, purchasedUnitsAfter: spend.state.purchasedUnits,
    };
  });
}

export interface GrantArgs {
  ownerKey: string;
  ownerId: string;
  ownerType: "user" | "school";
  /** Stable, unique id for the purchase — the hash of the Play purchase token. */
  purchaseKey: string;
  productId: string;
  credits: number;
  orderId: string | null;
  nowMs: number;
  /**
   * The raw Play purchase token, kept ONLY on the server-only processedPurchases
   * document so an acknowledgement that failed can be retried inside Google's
   * 3-day window; it is deleted once the purchase is acknowledged, and never
   * written to any log.
   */
  purchaseToken?: string;
  /** Extra audit facts stored on the processed-purchase record (purchase type, region, price verdict, ...). */
  extra?: Record<string, unknown>;
}

export interface GrantResult {
  duplicate: boolean;
  /** Credits actually ADDED to the balance (the purchase's credits minus any refund debt it repaid). */
  creditsGranted: number;
  /** Credits of this purchase that went to repaying an earlier refunded purchase. */
  debtRepaidCredits: number;
  freeUnitsAfter: number;
  purchasedUnitsAfter: number;
}

/**
 * Add purchased credits — idempotent per purchase, so a re-delivered receipt can
 * never credit twice. The processed-purchase record is created in the SAME
 * transaction as the credit, so "credited" and "recorded as processed" can't
 * disagree. Any refund debt on the account is repaid first (see RefundPolicy).
 */
export async function grantPurchase(db: Firestore, a: GrantArgs): Promise<GrantResult> {
  const ledgerRef = db.collection("creditLedgers").doc(a.ownerKey);
  const purchaseRef = db.collection("processedPurchases").doc(a.purchaseKey);
  const at = Timestamp.fromMillis(a.nowMs);
  const grossUnits = toUnits(a.credits);

  return db.runTransaction(async (tx) => {
    const ledgerSnap = await tx.get(ledgerRef);
    const purchaseSnap = await tx.get(purchaseRef);
    const existing = readLedger(ledgerSnap.data());
    if (purchaseSnap.exists) {
      return { duplicate: true, creditsGranted: 0, debtRepaidCredits: 0, freeUnitsAfter: existing.freeUnits, purchasedUnitsAfter: existing.purchasedUnits };
    }
    const debt = Math.max(0, Number(ledgerSnap.data()?.debtUnits ?? 0) || 0);
    const repaid = Math.min(debt, grossUnits);
    const creditedUnits = grossUnits - repaid;
    const next: LedgerState = { ...existing, purchasedUnits: existing.purchasedUnits + creditedUnits };
    tx.set(
      ledgerRef,
      {
        ownerType: a.ownerType, ownerId: a.ownerId, purchasedUnits: next.purchasedUnits, freeUnits: next.freeUnits,
        freePeriod: next.freePeriod, debtUnits: debt - repaid, updatedAt: at, ...(ledgerSnap.exists ? {} : { createdAt: at }),
      },
      { merge: true }
    );
    tx.set(ledgerRef.collection("transactions").doc(), {
      type: "purchase", units: creditedUnits, grossUnits, debtRepaidUnits: repaid, productId: a.productId, orderId: a.orderId,
      freeAfter: next.freeUnits, purchasedAfter: next.purchasedUnits, at,
    });
    tx.set(purchaseRef, {
      ownerKey: a.ownerKey, ownerId: a.ownerId, productId: a.productId, credits: a.credits, creditedUnits, debtRepaidUnits: repaid,
      orderId: a.orderId, status: "credited", ackStatus: "pending", ackAttempts: 0, createdAtMs: a.nowMs, at,
      ...(a.purchaseToken ? { purchaseToken: a.purchaseToken } : {}),
      ...(a.extra ?? {}),
    });
    return {
      duplicate: false, creditsGranted: fromUnits(creditedUnits), debtRepaidCredits: fromUnits(repaid),
      freeUnitsAfter: next.freeUnits, purchasedUnitsAfter: next.purchasedUnits,
    };
  });
}

export { safeId as hashId, FieldValue };

// ======================================================================
// Non-marking AI features (lesson plan, scheme of work, transcription, ...)
// share the SAME ledger, free allowance and purchased credits as marking; a
// use costs the feature's weight (see DEFAULT_FEATURE_WEIGHTS_*). The
// difference is the optional AD PASS: a rewarded ad, verified by AdMob
// server-side (adPass.ts), earns a pass that pays for exactly ONE generation.
// Passes are never accepted for marking (a marked script costs far more than
// an ad earns).
// ======================================================================

/** Read-only affordability check for one use of [feature]; only bites when featuresMode is "enforced". */
export async function checkCanAffordFeature(
  db: Firestore,
  ownerKey: string,
  cfg: MarkingCreditsConfig,
  feature: string,
  nowMs: number
): Promise<{ ok: boolean; needUnits: number; availableUnits: number }> {
  const needUnits = toUnits(featureWeight(cfg, nowMs, feature));
  if (cfg.featuresMode !== "enforced" || needUnits <= 0) return { ok: true, needUnits, availableUnits: 0 };
  const snap = await db.collection("creditLedgers").doc(ownerKey).get();
  const avail = availableUnits(rollFreeAllowance(readLedger(snap.data()), cfg, nowMs).state); // virtual — nothing written
  return { ok: avail >= needUnits, needUnits, availableUnits: avail };
}

/**
 * The id of one of [uid]'s unused, unexpired ad passes, or null. Passes are few
 * (capped per day, short-lived), so this filters in memory rather than needing
 * a composite index.
 */
export async function findUsableAdPass(db: Firestore, uid: string, nowMs: number): Promise<string | null> {
  const snap = await db.collection("adPasses").where("uid", "==", uid).limit(50).get();
  let best: { id: string; expiresAtMs: number } | null = null;
  for (const d of snap.docs) {
    const v = d.data();
    if (v.used === true || typeof v.expiresAtMs !== "number" || v.expiresAtMs <= nowMs) continue;
    if (!best || v.expiresAtMs < best.expiresAtMs) best = { id: d.id, expiresAtMs: v.expiresAtMs }; // soonest-to-expire first
  }
  return best?.id ?? null;
}

export interface FeatureChargeArgs {
  ownerKey: string;
  ownerId: string;
  ownerType: "user" | "school";
  feature: string;
  requestId?: string;
  cfg: MarkingCreditsConfig;
  nowMs: number;
  fn: string;
  /** Pay with this ad pass instead of credits (enforced mode only). */
  adPassId?: string | null;
}

export interface FeatureChargeResult {
  mode: CreditsMode;
  charged: boolean;
  duplicate: boolean;
  units: number;
  weight: number;
  shortfallUnits: number;
  freeUnitsAfter: number;
  purchasedUnitsAfter: number;
  paidWith: "credits" | "ad" | "none";
}

/**
 * Charge ONE successful use of a feature — same guarantees as marking: exactly
 * once per requestId, never below zero, off/shadow never touch a balance.
 * With an [FeatureChargeArgs.adPassId] the pass is consumed INSTEAD of credits,
 * atomically with the duplicate-marker; a pass that has meanwhile been used or
 * has expired falls back to charging credits (never a free use).
 */
export async function chargeSuccessfulFeature(db: Firestore, a: FeatureChargeArgs): Promise<FeatureChargeResult> {
  const weight = featureWeight(a.cfg, a.nowMs, a.feature);
  const units = toUnits(weight);
  const noop: FeatureChargeResult = {
    mode: a.cfg.featuresMode, charged: false, duplicate: false, units, weight, shortfallUnits: 0, freeUnitsAfter: 0, purchasedUnitsAfter: 0, paidWith: "none",
  };
  if (a.cfg.featuresMode === "off" || units <= 0) return noop;

  const ledgerRef = db.collection("creditLedgers").doc(a.ownerKey);
  // A different key space from marking's, and per FEATURE: the same requestId can never collide across
  // marking, or between two different features, so one can't be skipped as a "duplicate" of the other.
  const chargeRef = a.requestId ? ledgerRef.collection("charges").doc(safeId(`feature:${a.feature}:${a.requestId}`)) : undefined;
  const passRef = a.adPassId ? db.collection("adPasses").doc(a.adPassId) : undefined;
  const at = Timestamp.fromMillis(a.nowMs);
  const detail = { kind: "feature", feature: a.feature, weight, fn: a.fn, requestId: a.requestId ?? null, at };

  return db.runTransaction(async (tx) => {
    const ledgerSnap = await tx.get(ledgerRef);
    const chargeSnap = chargeRef ? await tx.get(chargeRef) : undefined;
    const passSnap = passRef ? await tx.get(passRef) : undefined;
    const existing = readLedger(ledgerSnap.data());

    if (chargeSnap?.exists) {
      return { ...noop, duplicate: true, freeUnitsAfter: existing.freeUnits, purchasedUnitsAfter: existing.purchasedUnits };
    }

    if (a.cfg.featuresMode === "shadow") {
      tx.set(ledgerRef.collection("transactions").doc(), { type: "shadow_spend", units: -units, mode: "shadow", ...detail });
      if (chargeRef) tx.set(chargeRef, { units, mode: "shadow", at });
      return { ...noop, freeUnitsAfter: existing.freeUnits, purchasedUnitsAfter: existing.purchasedUnits };
    }

    // Enforced. An ad pass, if still valid and this user's, pays for the whole use.
    const pass = passSnap?.data();
    if (passRef && pass && pass.uid === a.ownerId && pass.used !== true && typeof pass.expiresAtMs === "number" && pass.expiresAtMs > a.nowMs) {
      tx.update(passRef, { used: true, usedAtMs: a.nowMs, usedFor: a.feature, usedRequestId: a.requestId ?? null });
      tx.set(ledgerRef.collection("transactions").doc(), { type: "ad_pass_spend", units: 0, passId: a.adPassId, mode: "enforced", ...detail });
      if (chargeRef) tx.set(chargeRef, { units: 0, mode: "enforced", paidWith: "ad", at });
      return { ...noop, charged: true, units: 0, paidWith: "ad" as const, freeUnitsAfter: existing.freeUnits, purchasedUnitsAfter: existing.purchasedUnits };
    }

    const roll = rollFreeAllowance(existing, a.cfg, a.nowMs);
    if (roll.granted > 0 || roll.expired > 0) {
      tx.set(ledgerRef.collection("transactions").doc(), {
        type: "free_grant", units: roll.granted, expiredUnits: roll.expired, period: roll.state.freePeriod, at,
      });
    }
    const spend = applySpend(roll.state, units);
    tx.set(
      ledgerRef,
      {
        ownerType: a.ownerType, ownerId: a.ownerId, purchasedUnits: spend.state.purchasedUnits, freeUnits: spend.state.freeUnits,
        freePeriod: spend.state.freePeriod, updatedAt: at, ...(ledgerSnap.exists ? {} : { createdAt: at }),
      },
      { merge: true }
    );
    const charged = units - spend.shortfall;
    tx.set(ledgerRef.collection("transactions").doc(), {
      type: "spend", units: -charged, shortfallUnits: spend.shortfall, fromFreeUnits: spend.fromFree,
      fromPurchasedUnits: spend.fromPurchased, freeAfter: spend.state.freeUnits, purchasedAfter: spend.state.purchasedUnits,
      mode: "enforced", ...detail,
    });
    if (chargeRef) tx.set(chargeRef, { units: charged, mode: "enforced", paidWith: "credits", at });
    return {
      ...noop, charged: true, units: charged, shortfallUnits: spend.shortfall, paidWith: "credits" as const,
      freeUnitsAfter: spend.state.freeUnits, purchasedUnitsAfter: spend.state.purchasedUnits,
    };
  });
}
