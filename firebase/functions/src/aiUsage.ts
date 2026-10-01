// Token/cost tracking for the NON-marking AI features (the marking functions
// have their own, richer log in usageLog.ts). Every Gemini call made while a
// request is being served is recorded against that request's feature, so the
// owner can see the REAL cost of a lesson plan, a transcription, and so on
// next to the credits charged for it — the feature credit weights are
// estimates, and this is what lets them be corrected from data.
//
// How: `metered()` (featureBilling.ts) opens an AsyncLocalStorage scope for the
// request, and the functions call Gemini through `generateTracked`, which adds
// a record to that scope when there is one (and is a plain pass-through when
// there isn't, e.g. inside the marking functions). One batched write per
// request, at the end.
//
// PRIVACY: token counts and a one-way user hash only — never prompts, images
// or model output.
import { AsyncLocalStorage } from "node:async_hooks";
import type { GoogleGenAI } from "@google/genai";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { estimateCostUsd, extractUsage, hashUid, type GeminiUsage, type PricingTable } from "./usageLog";

export interface TrackedCall {
  model: string;
  usage: GeminiUsage;
  finishReason: string | null;
}

export interface UsageContext {
  feature: string;
  uid: string;
  requestId: string | null;
  calls: TrackedCall[];
}

const store = new AsyncLocalStorage<UsageContext>();

export const newUsageContext = (feature: string, uid: string, requestId?: string | null): UsageContext => ({
  feature, uid, requestId: requestId ?? null, calls: [],
});

/** Run [fn] with [ctx] as the current usage scope. */
export const runWithUsage = <T>(ctx: UsageContext, fn: () => Promise<T>): Promise<T> => store.run(ctx, fn);

type GenParams = Parameters<GoogleGenAI["models"]["generateContent"]>[0];

/** `ai.models.generateContent(params)` that also records token usage in the current scope, if any. */
export async function generateTracked(ai: GoogleGenAI, params: GenParams) {
  const response = await ai.models.generateContent(params);
  try {
    store.getStore()?.calls.push({
      model: String((params as { model?: unknown }).model ?? "unknown"),
      usage: extractUsage(response),
      finishReason: response.candidates?.[0]?.finishReason ?? null,
    });
  } catch {
    // tracking must never break a real response
  }
  return response;
}

export interface FeatureUsageRecord {
  feature: string;
  model: string;
  attempt: number;
  ok: boolean;
  finishReason: string | null;
  promptTokens: number;
  outputTokens: number;
  thinkingTokens: number;
  imageTokens: number;
  costUsd: number | null;
  uidHash: string;
  requestId: string | null;
  atMs: number;
}

export function buildFeatureRecords(ctx: UsageContext, ok: boolean, nowMs: number, pricing: PricingTable): FeatureUsageRecord[] {
  return ctx.calls.map((c, i) => ({
    feature: ctx.feature, model: c.model, attempt: i + 1,
    // Only the LAST call of a successful request produced the result; earlier ones were retries/steps.
    ok: ok && i === ctx.calls.length - 1,
    finishReason: c.finishReason,
    promptTokens: c.usage.promptTokens, outputTokens: c.usage.outputTokens, thinkingTokens: c.usage.thinkingTokens,
    imageTokens: c.usage.imageTokens,
    costUsd: estimateCostUsd(c.model, c.usage, pricing, nowMs),
    uidHash: hashUid(ctx.uid), requestId: ctx.requestId, atMs: nowMs,
  }));
}

/**
 * Persist a request's recorded calls and bump the running per-feature totals.
 * `successes` counts requests (not calls) that produced a result, while
 * `costUsd` counts every call — so measured cost per use honestly includes
 * multi-step features (research + structure) and wasted retries.
 */
export async function flushFeatureUsage(db: Firestore, ctx: UsageContext, ok: boolean, nowMs: number, pricing: PricingTable): Promise<number> {
  const records = buildFeatureRecords(ctx, ok, nowMs, pricing);
  const totalCostUsd = records.reduce((s, r) => s + (r.costUsd ?? 0), 0);
  if (records.length === 0 && !ok) return 0; // nothing was spent and nothing succeeded
  const batch = db.batch();
  for (const r of records) batch.set(db.collection("featureUsage").doc(), { ...r, at: Timestamp.fromMillis(nowMs) });
  const sum = (f: (r: FeatureUsageRecord) => number) => records.reduce((s, r) => s + f(r), 0);
  batch.set(
    db.collection("ownerData").doc("usageAgg"),
    {
      features: {
        [ctx.feature]: {
          requests: FieldValue.increment(1),
          successes: FieldValue.increment(ok ? 1 : 0),
          calls: FieldValue.increment(records.length),
          costUsd: FieldValue.increment(sum((r) => r.costUsd ?? 0)),
          unpricedCalls: FieldValue.increment(records.filter((r) => r.costUsd === null).length),
          promptTokens: FieldValue.increment(sum((r) => r.promptTokens)),
          outputTokens: FieldValue.increment(sum((r) => r.outputTokens)),
          thinkingTokens: FieldValue.increment(sum((r) => r.thinkingTokens)),
          imageTokens: FieldValue.increment(sum((r) => r.imageTokens)),
        },
      },
      updatedAt: Timestamp.fromMillis(nowMs),
    },
    { merge: true }
  );
  await batch.commit();
  return totalCostUsd;
}
