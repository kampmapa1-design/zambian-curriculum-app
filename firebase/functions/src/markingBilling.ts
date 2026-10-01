// Runtime glue between the two marking Cloud Functions and the credit ledger /
// usage log (Monetization Stages 1-3 and 6). Kept out of index.ts so the
// marking functions only gain a few clearly-labelled calls.
//
// FAILURE POLICY — deliberate, and worth stating once:
//  * The affordability check throws ONLY for a genuine "not enough credits".
//    If the ledger can't be read (Firestore hiccup) the teacher is NOT blocked.
//  * Logging and charging NEVER fail a marking request. The marking already
//    happened and the teacher is owed their result; a billing write that
//    fails is logged loudly ("BILLING_CHARGE_FAILED") and the request still
//    succeeds. The cost of that is one unbilled script, not a broken app.
import { HttpsError } from "firebase-functions/v2/https";
import type { Firestore } from "firebase-admin/firestore";
import {
  DEFAULT_MARKING_CREDITS_CONFIG,
  availableUnits,
  checkCanAfford,
  chargeSuccessfulMarking,
  fromUnits,
  parseMarkingCreditsConfig,
  userOwnerKey,
  type MarkingCreditsConfig,
  type MarkingEngine,
} from "./credits";
import {
  DEFAULT_PRICING,
  buildUsageRecord,
  extractUsage,
  logMarkingUsage,
  type PricingTable,
} from "./usageLog";
import { parseOwnerSettings } from "./revenue";

const CONFIG_TTL_MS = 60_000;
let configCache: { cfg: MarkingCreditsConfig; atMs: number } | null = null;
let pricingCache: { pricing: PricingTable; atMs: number } | null = null;

/** Test hook — drops cached config/pricing. */
export function resetBillingCaches(): void {
  configCache = null;
  pricingCache = null;
}

/**
 * The live credits config (Firestore `appConfig/markingCredits`), cached for a
 * minute per instance. Never throws: on a read failure it keeps the last good
 * copy, and with none it uses the safe default (mode "off").
 */
export async function loadCreditsConfig(db: Firestore, nowMs: number): Promise<MarkingCreditsConfig> {
  if (configCache && nowMs - configCache.atMs < CONFIG_TTL_MS) return configCache.cfg;
  try {
    const snap = await db.collection("appConfig").doc("markingCredits").get();
    const cfg = snap.exists ? parseMarkingCreditsConfig(snap.data()) : parseMarkingCreditsConfig(undefined);
    configCache = { cfg, atMs: nowMs };
    return cfg;
  } catch (err) {
    console.error("markingBilling: could not read appConfig/markingCredits", err);
    return configCache?.cfg ?? DEFAULT_MARKING_CREDITS_CONFIG;
  }
}

export async function loadPricing(db: Firestore, nowMs: number): Promise<PricingTable> {
  if (pricingCache && nowMs - pricingCache.atMs < 5 * CONFIG_TTL_MS) return pricingCache.pricing;
  try {
    const settings = parseOwnerSettings((await db.collection("ownerData").doc("settings").get()).data());
    const pricing = settings.geminiPricing ?? DEFAULT_PRICING;
    pricingCache = { pricing, atMs: nowMs };
    return pricing;
  } catch {
    return pricingCache?.pricing ?? DEFAULT_PRICING;
  }
}

/** A client request id is only trusted as an idempotency key if it looks like one. */
export function cleanRequestId(v: unknown): string | undefined {
  return typeof v === "string" && v.length >= 8 && v.length <= 128 ? v : undefined;
}

export interface CreditsInfo {
  mode: "shadow" | "enforced";
  /** Credits actually taken for this script (0 when it was already charged, or in shadow mode). */
  charged: number;
  /** What this script costs at the current weights (credits). */
  cost: number;
  /** The per-page weight applied. */
  weightPerPage: number;
  /** True when this exact request was already charged (a retry) and nothing more was taken. */
  duplicate: boolean;
  /** Balance after this call, in credits (enforced mode only). */
  balance: number | null;
}

export interface BillingStart {
  db: Firestore;
  fn: "concise" | "legacy";
  uid: string;
  requestId?: unknown;
  engine: MarkingEngine;
  /** Answer-script pages being marked (question-paper images are not billed). */
  pages: number;
  questionCount: number;
}

export interface MarkingBilling {
  readonly cfg: MarkingCreditsConfig;
  /** Record one Gemini attempt's token usage. Never throws. */
  recordAttempt(a: { model: string; attempt: number; ok: boolean; response?: unknown; finishReason?: string | null }): Promise<void>;
  /** Charge ONCE for a successful result. Call it only after a valid, readable result exists. Never throws. */
  settle(): Promise<CreditsInfo | undefined>;
}

/**
 * Begin billing for one marking request: load config, and (enforced mode only)
 * refuse BEFORE the paid AI call if the balance can't cover the script.
 */
export async function beginMarkingBilling(s: BillingStart): Promise<MarkingBilling> {
  const nowMs = Date.now(); // SERVER time — a client-reported date is never used for pricing.
  const cfg = await loadCreditsConfig(s.db, nowMs);
  const requestId = cleanRequestId(s.requestId);
  const ownerKey = userOwnerKey(s.uid);

  if (cfg.mode === "enforced") {
    let check: Awaited<ReturnType<typeof checkCanAfford>> | null = null;
    try {
      check = await checkCanAfford(s.db, ownerKey, cfg, s.engine, s.pages, nowMs);
    } catch (err) {
      console.error("markingBilling: affordability check failed — letting the request through", err);
    }
    if (check && !check.ok) {
      const need = fromUnits(check.needUnits);
      const have = fromUnits(check.availableUnits);
      throw new HttpsError(
        "failed-precondition",
        `Not enough marking credits: this script needs ${need} and you have ${have}. Buy a credit bundle to continue.`,
        { code: "insufficient_credits", requiredCredits: need, availableCredits: have }
      );
    }
  }

  let settled = false;
  return {
    cfg,
    async recordAttempt(a) {
      try {
        const pricing = await loadPricing(s.db, nowMs);
        await logMarkingUsage(
          s.db,
          buildUsageRecord({
            fn: s.fn, engine: s.engine, model: a.model, pages: s.pages, questionCount: s.questionCount, attempt: a.attempt,
            ok: a.ok, finishReason: a.finishReason ?? null, usage: extractUsage(a.response), uid: s.uid,
            requestId: requestId ?? null, nowMs: Date.now(), pricing,
          })
        );
      } catch (err) {
        console.error("markingBilling: could not log token usage", err);
      }
    },
    async settle() {
      if (settled) return undefined; // belt and braces: one settle per request
      settled = true;
      if (cfg.mode === "off") return undefined;
      try {
        const r = await chargeSuccessfulMarking(s.db, {
          ownerKey, ownerId: s.uid, ownerType: "user", engine: s.engine, pages: s.pages, requestId, cfg, nowMs, fn: s.fn,
        });
        return {
          mode: cfg.mode,
          charged: r.charged ? fromUnits(r.units) : 0,
          cost: fromUnits(r.units),
          weightPerPage: r.weight,
          duplicate: r.duplicate,
          balance: cfg.mode === "enforced" ? fromUnits(availableUnits({ purchasedUnits: r.purchasedUnitsAfter, freeUnits: r.freeUnitsAfter, freePeriod: null })) : null,
        };
      } catch (err) {
        console.error(`BILLING_CHARGE_FAILED uid=${s.uid} engine=${s.engine} pages=${s.pages} requestId=${requestId ?? "-"}`, err);
        return undefined;
      }
    },
  };
}
