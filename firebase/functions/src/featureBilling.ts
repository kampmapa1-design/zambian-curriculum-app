// Metering for every NON-marking AI feature (lesson plan, scheme of work,
// teaching notes, transcription, marking-key derivation, home-assignment
// generation, minutes, timetable helpers, ...). Wraps a Cloud Function's
// handler so that it:
//   1. BEFORE any AI call: refuses if the caller can afford neither the
//      feature's credits nor an ad pass (featuresMode "enforced" only);
//   2. runs the handler with token-usage tracking on;
//   3. AFTER it returns without throwing — i.e. only for a successful
//      generation — charges once (exactly-once per requestId), paying with
//      an ad pass if that is what the caller chose or had to use;
//   4. records the real token cost of the request either way.
//
// Same failure policy as marking (see markingBilling.ts): only a genuine
// "not enough credits" blocks a user; a billing/logging problem never fails a
// generation that already succeeded.
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import type { Firestore } from "firebase-admin/firestore";
import {
  availableUnits,
  chargeSuccessfulFeature,
  checkCanAffordFeature,
  featureWeight,
  findUsableAdPass,
  fromUnits,
  userOwnerKey,
  type CreditsMode,
} from "./credits";
import { cleanRequestId, loadCreditsConfig, loadPricing } from "./markingBilling";
import { flushFeatureUsage, newUsageContext, runWithUsage, type UsageContext } from "./aiUsage";
import { addSchoolUsageUsd, isWithinAllowance, readSchoolUsageUsd, type SchoolAllowanceOption } from "./schoolAllowance";

export interface FeatureCreditsInfo {
  mode: "shadow" | "enforced";
  feature: string;
  /** Credits taken for this generation (0 when paid with an ad pass, already charged, or in shadow mode). */
  charged: number;
  /** What this generation costs at the current weights. */
  cost: number;
  /** "plan" = inside the school's included allowance, so nothing was charged. */
  paidWith: "credits" | "ad" | "plan" | "none";
  duplicate: boolean;
  /** Balance after this call, in credits (enforced mode only). */
  balance: number | null;
}

export interface FeatureBillingStart {
  db: Firestore;
  feature: string;
  uid: string;
  requestId?: unknown;
  /** "ad" = pay with an ad pass rather than credits. Anything else = credits (with an ad pass as the fallback). */
  payWith?: unknown;
  fn: string;
  /** Subscribed-school included allowance for this feature group, if it has one. */
  allowance?: SchoolAllowanceOption;
  /** The raw request data - only used to find the school id for [allowance]. */
  data?: unknown;
}

export interface FeatureBilling {
  readonly mode: CreditsMode;
  /** Charge once for a successful generation. Never throws. */
  settle(): Promise<FeatureCreditsInfo | undefined>;
}

export async function beginFeatureBilling(s: FeatureBillingStart): Promise<FeatureBilling> {
  const nowMs = Date.now(); // SERVER time — never a client-reported date.
  const cfg = await loadCreditsConfig(s.db, nowMs);
  const requestId = cleanRequestId(s.requestId);
  const ownerKey = userOwnerKey(s.uid);
  const weight = featureWeight(cfg, nowMs, s.feature);
  const chargeable = cfg.featuresMode === "enforced" && weight > 0;

  // A subscribed school's use is INCLUDED while its measured AI spend this month is
  // still under the allowance; after that it is charged like any other use. A read
  // failure fails open (included) rather than block or charge on an infrastructure error.
  let coveredByPlan = false;
  if (s.allowance && cfg.featuresMode !== "off" && weight > 0) {
    const schoolId = s.allowance.schoolId(s.data);
    const allowanceUsd = cfg.schoolAllowancesUsd[s.allowance.group] ?? 0;
    if (schoolId && allowanceUsd > 0) {
      try {
        coveredByPlan = isWithinAllowance(await readSchoolUsageUsd(s.db, schoolId, s.allowance.group, nowMs), allowanceUsd);
      } catch (err) {
        console.error("featureBilling: could not read the school's included usage — treating as included", err);
        coveredByPlan = true;
      }
    }
  }

  let adPassId: string | null = null;
  if (chargeable && !coveredByPlan) {
    const wantAd = s.payWith === "ad";
    if (wantAd) {
      adPassId = cfg.adPasses.enabled ? await findUsableAdPass(s.db, s.uid, nowMs).catch(() => null) : null;
      if (!adPassId) {
        throw new HttpsError("failed-precondition", "You don't have an ad pass to use. Watch an ad first, or use your credits.", {
          code: "ad_pass_required", feature: s.feature,
        });
      }
    } else {
      let check: Awaited<ReturnType<typeof checkCanAffordFeature>> | null = null;
      try {
        check = await checkCanAffordFeature(s.db, ownerKey, cfg, s.feature, nowMs);
      } catch (err) {
        console.error("featureBilling: affordability check failed — letting the request through", err);
      }
      if (check && !check.ok) {
        // Can't afford it in credits — an unused ad pass, if there is one, pays for this one.
        adPassId = cfg.adPasses.enabled ? await findUsableAdPass(s.db, s.uid, nowMs).catch(() => null) : null;
        if (!adPassId) {
          const need = fromUnits(check.needUnits);
          const have = fromUnits(check.availableUnits);
          throw new HttpsError(
            "failed-precondition",
            `Not enough credits: this needs ${need} and you have ${have}. Get more credits${cfg.adPasses.enabled ? " or watch an ad to use it once" : ""} to continue.`,
            { code: "insufficient_credits", feature: s.feature, requiredCredits: need, availableCredits: have, adPassEligible: cfg.adPasses.enabled }
          );
        }
      }
    }
  }

  let settled = false;
  return {
    mode: cfg.featuresMode,
    async settle() {
      if (settled) return undefined;
      settled = true;
      if (cfg.featuresMode === "off" || weight <= 0) return undefined; // nothing to charge, nothing to report
      if (coveredByPlan) {
        return { mode: cfg.featuresMode, feature: s.feature, charged: 0, cost: weight, paidWith: "plan", duplicate: false, balance: null };
      }
      try {
        const r = await chargeSuccessfulFeature(s.db, {
          ownerKey, ownerId: s.uid, ownerType: "user", feature: s.feature, requestId, cfg, nowMs, fn: s.fn, adPassId,
        });
        if (r.mode === "off") return undefined;
        return {
          mode: r.mode,
          feature: s.feature,
          charged: r.charged ? fromUnits(r.units) : 0,
          cost: fromUnits(r.units || Math.round(weight * 1000)),
          paidWith: r.paidWith,
          duplicate: r.duplicate,
          balance: r.mode === "enforced" ? fromUnits(availableUnits({ purchasedUnits: r.purchasedUnitsAfter, freeUnits: r.freeUnitsAfter, freePeriod: null })) : null,
        };
      } catch (err) {
        console.error(`BILLING_CHARGE_FAILED uid=${s.uid} feature=${s.feature} requestId=${requestId ?? "-"}`, err);
        return undefined;
      }
    },
  };
}

/** Best-effort persist of a request's token usage; never throws. */
async function recordUsage(db: Firestore, ctx: UsageContext, ok: boolean, allowance?: SchoolAllowanceOption, data?: unknown): Promise<void> {
  try {
    const nowMs = Date.now();
    const costUsd = await flushFeatureUsage(db, ctx, ok, nowMs, await loadPricing(db, nowMs));
    // Count the real spend against the school's included allowance (whether or not charging is on).
    const schoolId = allowance?.schoolId(data);
    if (allowance && schoolId && costUsd > 0) await addSchoolUsageUsd(db, schoolId, allowance.group, nowMs, costUsd);
  } catch (err) {
    console.error("featureBilling: could not log feature token usage", err);
  }
}

export interface MeteredOptions<Res> {
  /**
   * For a handler that can return normally without producing a real result
   * (an empty enrichment, say): return false to treat that as "not a
   * successful generation" — nothing is charged.
   */
  isUsable?: (result: Res) => boolean;
  /** Included allowance for subscribed schools (see schoolAllowance.ts). */
  schoolAllowance?: SchoolAllowanceOption;
}

/**
 * Wrap a callable's handler so it is metered as [feature]. The response gains
 * an optional `credits` block (only in shadow/enforced mode).
 */
export function metered<Req, Res>(
  feature: string,
  handler: (request: CallableRequest<Req>) => Promise<Res>,
  options: MeteredOptions<Res> = {}
): (request: CallableRequest<Req>) => Promise<Res> {
  return async (request) => {
    if (!request.auth) return handler(request); // the handler's own "sign in" error, unchanged
    const db = admin.firestore();
    const data = (request.data ?? {}) as { requestId?: unknown; payWith?: unknown };
    const billing = await beginFeatureBilling({
      db, feature, uid: request.auth.uid, requestId: data.requestId, payWith: data.payWith, fn: feature,
      allowance: options.schoolAllowance, data: request.data,
    });

    const ctx = newUsageContext(feature, request.auth.uid, cleanRequestId(data.requestId));
    let ok = false;
    try {
      const result = await runWithUsage(ctx, () => handler(request));
      ok = options.isUsable ? options.isUsable(result) : true;
      if (ok) {
        const credits = await billing.settle();
        if (credits && result && typeof result === "object" && !Array.isArray(result)) {
          (result as Record<string, unknown>).credits = credits;
        }
      }
      return result;
    } finally {
      await recordUsage(db, ctx, ok, options.schoolAllowance, request.data);
    }
  };
}
