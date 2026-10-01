// Revenue tracking against the VAT-registration threshold (Monetization
// Stage 5, 2026-09-19) — and the owner-only settings/summary it feeds
// (Stages 7 and 8).
//
// HONEST LIMITS, please read before relying on the number:
//  * The revenue figure is the bundle's configured LIST price (converted to
//    kwacha at the stored exchange rate if it isn't already kwacha), not the
//    amount Google actually charged after local currency, VAT or fees. The
//    Play purchase API does not return the price, and a client-reported price
//    can't be trusted. It is a monitoring signal, not an accounting record.
//  * The K800,000 threshold is what we BELIEVE the ZRA VAT registration
//    threshold to be — UNVERIFIED. It is editable (ownerData/settings) so the
//    accountant can correct it without a deploy, and "turnover" for VAT
//    purposes may be defined differently from this rolling sum.
import type { Firestore } from "firebase-admin/firestore";
import { Timestamp } from "firebase-admin/firestore";
import type { MarkingCreditsConfig, MarkingEngine } from "./credits";
import { activeBundles, selectWeightSet } from "./credits";
import type { PricingTable } from "./usageLog";

export const DAY_MS = 24 * 60 * 60 * 1000;
export const DEFAULT_VAT_THRESHOLD_KWACHA = 800_000; // BELIEVED, unverified
export const DEFAULT_FX_USD_TO_ZMW = 20; // the owner's own figure (K70 = $3.50)
export const FX_STALE_DAYS = 60;

// Modelled cost per marked page (USD), Base scenario, 2026 Gemini prices — from
// docs/marking_pricing_model.py. What the dashboard compares MEASURED cost to.
export const DEFAULT_MODELED_COST_PER_PAGE_USD: Record<MarkingEngine, number> = {
  concise: 0.0083,
  stable: 0.0026,
  keyed: 0.0085,
};

/** Convert a list price to kwacha. Unknown currencies return null rather than a guess. */
export function toKwacha(amount: number, currency: string, fxUsdToZmw: number): number | null {
  const c = currency.toUpperCase();
  if (c === "ZMW") return amount;
  if (c === "USD") return amount * fxUsdToZmw;
  return null;
}

/** Sum of events inside the trailing 365 days. Pure. */
export function rollingTotal(events: { atMs: number; amountKwacha: number }[], nowMs: number): number {
  const from = nowMs - 365 * DAY_MS;
  return events.filter((e) => e.atMs > from && e.atMs <= nowMs).reduce((s, e) => s + e.amountKwacha, 0);
}

export interface RevenueEventInput {
  eventKey: string;
  /** Negative for a refund (a reversal), so the rolling total goes down. */
  amountKwacha: number;
  productId: string;
  atMs: number;
  orderId: string | null;
  /** Extra facts stored on the event (how the amount was known, Google's net-of-fees figure, ...). */
  extra?: Record<string, unknown>;
}

/** Idempotent: a repeated eventKey (same purchase) is ignored. */
export async function recordRevenueEvent(db: Firestore, e: RevenueEventInput): Promise<boolean> {
  const ref = db.collection("revenueEvents").doc(e.eventKey);
  return db.runTransaction(async (tx) => {
    if ((await tx.get(ref)).exists) return false;
    tx.set(ref, { amountKwacha: e.amountKwacha, productId: e.productId, orderId: e.orderId, atMs: e.atMs, at: Timestamp.fromMillis(e.atMs), ...(e.extra ?? {}) });
    return true;
  });
}

export interface RevenueSummary {
  rolling12mKwacha: number;
  eventCount: number;
  thresholdKwacha: number;
  vatThresholdCrossed: boolean;
  crossedAtMs: number | null;
  /** True only on the run that first crossed the threshold — the caller notifies the owner then. */
  crossedNow: boolean;
}

/**
 * Recompute the rolling 12-month total from the raw events and update the
 * single admin document. The threshold flag is STICKY: once crossed it stays
 * set even if later months fall out of the window — registration doesn't
 * un-happen. (Reads every event in the window; fine at this scale, switch to
 * an incremental aggregate if it ever reaches tens of thousands per year.)
 */
export async function updateRevenueSummary(db: Firestore, nowMs: number, thresholdKwacha: number): Promise<RevenueSummary> {
  const snap = await db.collection("revenueEvents").where("atMs", ">", nowMs - 365 * DAY_MS).get();
  const events = snap.docs.map((d) => ({ atMs: Number(d.get("atMs")), amountKwacha: Number(d.get("amountKwacha")) }));
  const total = rollingTotal(events, nowMs);

  const ref = db.collection("ownerData").doc("revenue");
  const prev = (await ref.get()).data();
  const wasCrossed = prev?.vatThresholdCrossed === true;
  const nowCrossed = wasCrossed || total >= thresholdKwacha;
  const crossedAtMs = wasCrossed ? (typeof prev?.crossedAtMs === "number" ? prev.crossedAtMs : nowMs) : nowCrossed ? nowMs : null;

  await ref.set(
    {
      rolling12mKwacha: total, eventCount: events.length, thresholdKwacha, vatThresholdCrossed: nowCrossed,
      crossedAtMs, updatedAtMs: nowMs, updatedAt: Timestamp.fromMillis(nowMs),
    },
    { merge: true }
  );
  return { rolling12mKwacha: total, eventCount: events.length, thresholdKwacha, vatThresholdCrossed: nowCrossed, crossedAtMs, crossedNow: nowCrossed && !wasCrossed };
}

// ------------------------------------------------------------------ owner settings (Stages 7-8)
export interface OwnerSettings {
  ownerUids: string[];
  ownerEmail: string | null;
  fxUsdToZmw: { rate: number; updatedAtMs: number | null };
  vatThresholdKwacha: number;
  geminiPricing: PricingTable | null;
  modeledCostPerPageUsd: Record<MarkingEngine, number>;
}

export function parseOwnerSettings(data: Record<string, unknown> | undefined): OwnerSettings {
  const d = data ?? {};
  const fx = (d.fxUsdToZmw ?? {}) as { rate?: unknown; updatedAtMs?: unknown };
  const modeled = (d.modeledCostPerPageUsd ?? {}) as Record<string, unknown>;
  const pos = (v: unknown, fallback: number) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : fallback);
  return {
    ownerUids: Array.isArray(d.ownerUids) ? d.ownerUids.filter((u): u is string => typeof u === "string" && u.length > 0) : [],
    ownerEmail: typeof d.ownerEmail === "string" && d.ownerEmail.includes("@") ? d.ownerEmail : null,
    fxUsdToZmw: { rate: pos(fx.rate, DEFAULT_FX_USD_TO_ZMW), updatedAtMs: typeof fx.updatedAtMs === "number" ? fx.updatedAtMs : null },
    vatThresholdKwacha: pos(d.vatThresholdKwacha, DEFAULT_VAT_THRESHOLD_KWACHA),
    geminiPricing: d.geminiPricing && typeof d.geminiPricing === "object" ? (d.geminiPricing as PricingTable) : null,
    modeledCostPerPageUsd: {
      concise: pos(modeled.concise, DEFAULT_MODELED_COST_PER_PAGE_USD.concise),
      stable: pos(modeled.stable, DEFAULT_MODELED_COST_PER_PAGE_USD.stable),
      keyed: pos(modeled.keyed, DEFAULT_MODELED_COST_PER_PAGE_USD.keyed),
    },
  };
}

export async function loadOwnerSettings(db: Firestore): Promise<OwnerSettings> {
  return parseOwnerSettings((await db.collection("ownerData").doc("settings").get()).data());
}

export const isOwnerUid = (s: OwnerSettings, uid: string): boolean => s.ownerUids.includes(uid);

/** Days since the exchange rate was last updated (null if it never has been), and whether that's stale (> 60 days). */
export function fxStatus(s: OwnerSettings, nowMs: number): { rate: number; updatedAtMs: number | null; daysSinceUpdate: number | null; stale: boolean } {
  const at = s.fxUsdToZmw.updatedAtMs;
  const days = at === null ? null : Math.floor((nowMs - at) / DAY_MS);
  return { rate: s.fxUsdToZmw.rate, updatedAtMs: at, daysSinceUpdate: days, stale: days === null || days > FX_STALE_DAYS };
}

export interface EngineUsageAgg {
  attempts?: number;
  successes?: number;
  pagesSuccessful?: number;
  costUsd?: number;
  unpricedAttempts?: number;
  promptTokens?: number;
  outputTokens?: number;
  thinkingTokens?: number;
  imageTokens?: number;
}

export interface FeatureUsageAgg {
  requests?: number;
  successes?: number;
  calls?: number;
  costUsd?: number;
  unpricedCalls?: number;
  promptTokens?: number;
  outputTokens?: number;
  thinkingTokens?: number;
  imageTokens?: number;
}

/** What one credit is meant to be worth in AI cost — the marking weights were built on ~$0.0026. */
export const TARGET_COST_PER_CREDIT_USD = 0.0026;

/** Assemble the owner finance dashboard payload. Pure — every input is passed in. */
export function buildFinanceSummary(input: {
  settings: OwnerSettings;
  revenue: Record<string, unknown> | undefined;
  usageAgg: { engines?: Record<string, EngineUsageAgg>; features?: Record<string, FeatureUsageAgg> } | undefined;
  cfg: MarkingCreditsConfig;
  nowMs: number;
}) {
  const { settings, revenue, usageAgg, cfg, nowMs } = input;
  const rolling = typeof revenue?.rolling12mKwacha === "number" ? revenue.rolling12mKwacha : 0;
  const threshold = settings.vatThresholdKwacha;
  const engines: MarkingEngine[] = ["concise", "stable", "keyed"];
  const usage = Object.fromEntries(
    engines.map((e) => {
      const a = usageAgg?.engines?.[e] ?? {};
      const pages = a.pagesSuccessful ?? 0;
      const measured = pages > 0 ? (a.costUsd ?? 0) / pages : null;
      const modeled = settings.modeledCostPerPageUsd[e];
      return [
        e,
        {
          attempts: a.attempts ?? 0,
          successes: a.successes ?? 0,
          pagesSuccessful: pages,
          measuredCostPerPageUsd: measured,
          modeledCostPerPageUsd: modeled,
          measuredVsModeled: measured === null ? null : measured / modeled,
          avgThinkingTokensPerAttempt: (a.attempts ?? 0) > 0 ? (a.thinkingTokens ?? 0) / (a.attempts as number) : null,
          unpricedAttempts: a.unpricedAttempts ?? 0,
        },
      ];
    })
  );
  const activeWeightSet = selectWeightSet(cfg, nowMs);
  // Non-marking features: measured real cost per SUCCESSFUL use vs the credits charged for it.
  // impliedCostPerCreditUsd well above the target means the weight under-charges that feature.
  const featureNames = new Set([...Object.keys(activeWeightSet.features), ...Object.keys(usageAgg?.features ?? {})]);
  const features = Object.fromEntries(
    [...featureNames].sort().map((name) => {
      const a = usageAgg?.features?.[name] ?? {};
      const successes = a.successes ?? 0;
      const measured = successes > 0 ? (a.costUsd ?? 0) / successes : null;
      const weight = activeWeightSet.features[name] ?? null;
      return [
        name,
        {
          requests: a.requests ?? 0,
          successes,
          calls: a.calls ?? 0,
          creditsPerUse: weight,
          measuredCostPerUseUsd: measured,
          impliedCostPerCreditUsd: measured !== null && weight !== null && weight > 0 ? measured / weight : null,
          unpricedCalls: a.unpricedCalls ?? 0,
        },
      ];
    })
  );
  const upcoming = cfg.weightSets.find((s) => Date.parse(s.effectiveFrom) > nowMs) ?? null;
  return {
    revenue: {
      rolling12mKwacha: rolling,
      thresholdKwacha: threshold,
      remainingKwacha: Math.max(0, threshold - rolling),
      percentOfThreshold: threshold > 0 ? (rolling / threshold) * 100 : 0,
      vatThresholdCrossed: revenue?.vatThresholdCrossed === true,
      crossedAtMs: typeof revenue?.crossedAtMs === "number" ? revenue.crossedAtMs : null,
      updatedAtMs: typeof revenue?.updatedAtMs === "number" ? revenue.updatedAtMs : null,
      basis: "Configured list price of verified purchases, not the amount Google actually charged.",
    },
    fx: fxStatus(settings, nowMs),
    usage,
    features,
    targetCostPerCreditUsd: TARGET_COST_PER_CREDIT_USD,
    config: {
      mode: cfg.mode,
      featuresMode: cfg.featuresMode,
      adPasses: cfg.adPasses,
      schoolAllowancesUsd: cfg.schoolAllowancesUsd,
      activeFeatureWeights: activeWeightSet.features,
      freeMonthlyCredits: cfg.freeMonthlyCredits,
      activeWeights: { effectiveFrom: activeWeightSet.effectiveFrom, ...activeWeightSet.weights },
      nextWeights: upcoming ? { effectiveFrom: upcoming.effectiveFrom, ...upcoming.weights } : null,
      activeScenario: cfg.bundles.activeScenario,
      bundles: Object.fromEntries(Object.entries(activeBundles(cfg)).map(([id, b]) => [id, { credits: b.credits, listPrice: b.listPrice }])),
    },
    generatedAtMs: nowMs,
  };
}
