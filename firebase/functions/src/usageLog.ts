// Marking token-usage instrumentation (Monetization Stage 6, 2026-09-19).
//
// Before this, the backend recorded NO token usage anywhere, so every
// per-page cost in docs/PRICING_AND_TAX_BRIEFING.md was a model, not a
// measurement. This logs one record per Gemini ATTEMPT (a retry that costs
// money is real cost, so it gets its own record) and keeps running per-engine
// totals so the owner dashboard can show measured average cost per page in
// one cheap read instead of scanning every record.
//
// PRIVACY: the user is stored only as a one-way hash. No images, answers or
// other content are ever logged — token COUNTS only.
import { createHash } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import type { MarkingEngine } from "./credits";

export interface GeminiUsage {
  promptTokens: number;
  outputTokens: number;
  thinkingTokens: number;
  imageTokens: number;
  totalTokens: number;
}

const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);

/** Pull token counts off a Gemini response (`usageMetadata`); every field defaults to 0 if absent. */
export function extractUsage(response: unknown): GeminiUsage {
  const m = (response as { usageMetadata?: Record<string, unknown> } | null | undefined)?.usageMetadata ?? {};
  const details = Array.isArray(m.promptTokensDetails) ? (m.promptTokensDetails as Record<string, unknown>[]) : [];
  const imageTokens = details
    .filter((d) => String(d?.modality ?? "").toUpperCase() === "IMAGE")
    .reduce((sum, d) => sum + num(d.tokenCount), 0);
  return {
    promptTokens: num(m.promptTokenCount),
    outputTokens: num(m.candidatesTokenCount),
    thinkingTokens: num(m.thoughtsTokenCount),
    imageTokens,
    totalTokens: num(m.totalTokenCount),
  };
}

export interface ModelPrice {
  effectiveFrom: string;
  inputPerM: number;
  outputPerM: number;
}
export type PricingTable = Record<string, ModelPrice[]>;

// VERIFIED against Google's pricing page on 2026-09-19. Output prices already
// INCLUDE thinking tokens (Google bills them as output). Overridable at
// runtime via ownerData/settings.geminiPricing so a price change needs no deploy.
export const DEFAULT_PRICING: PricingTable = {
  "gemini-3.6-flash": [
    { effectiveFrom: "2026-01-01T00:00:00Z", inputPerM: 0.75, outputPerM: 3.75 },
    { effectiveFrom: "2027-01-01T00:00:00Z", inputPerM: 1.5, outputPerM: 7.5 },
  ],
  "gemini-3.5-flash-lite": [{ effectiveFrom: "2026-01-01T00:00:00Z", inputPerM: 0.3, outputPerM: 2.5 }],
};

/** USD cost of one attempt, or null when the model has no known price. Thinking tokens are billed as output. */
export function estimateCostUsd(model: string, u: GeminiUsage, table: PricingTable, nowMs: number): number | null {
  const prices = table[model];
  if (!prices || prices.length === 0) return null;
  let p = prices[0];
  for (const candidate of prices) {
    if (Date.parse(candidate.effectiveFrom) <= nowMs) p = candidate;
  }
  return (u.promptTokens * p.inputPerM + (u.outputTokens + u.thinkingTokens) * p.outputPerM) / 1e6;
}

/** One-way, stable pseudonym for a user id — lets us group one user's calls without storing who they are. */
export const hashUid = (uid: string): string =>
  createHash("sha256").update(`marking-usage:${uid}`).digest("hex").slice(0, 32);

export interface UsageRecordInput {
  fn: "concise" | "legacy";
  engine: MarkingEngine;
  model: string;
  pages: number;
  questionCount: number;
  attempt: number;
  ok: boolean;
  finishReason: string | null;
  usage: GeminiUsage;
  uid: string;
  requestId?: string | null;
  nowMs: number;
  pricing: PricingTable;
}

export interface UsageRecord {
  fn: string;
  engine: MarkingEngine;
  model: string;
  pages: number;
  questionCount: number;
  attempt: number;
  ok: boolean;
  finishReason: string | null;
  promptTokens: number;
  outputTokens: number;
  thinkingTokens: number;
  imageTokens: number;
  totalTokens: number;
  costUsd: number | null;
  uidHash: string;
  requestId: string | null;
  atMs: number;
}

export function buildUsageRecord(i: UsageRecordInput): UsageRecord {
  return {
    fn: i.fn, engine: i.engine, model: i.model, pages: i.pages, questionCount: i.questionCount, attempt: i.attempt,
    ok: i.ok, finishReason: i.finishReason,
    promptTokens: i.usage.promptTokens, outputTokens: i.usage.outputTokens, thinkingTokens: i.usage.thinkingTokens,
    imageTokens: i.usage.imageTokens, totalTokens: i.usage.totalTokens,
    costUsd: estimateCostUsd(i.model, i.usage, i.pricing, i.nowMs),
    uidHash: hashUid(i.uid), requestId: i.requestId ?? null, atMs: i.nowMs,
  };
}

/**
 * Write one usage record AND bump the per-engine running totals. `costUsd`
 * counts every attempt (retries included) while `pagesSuccessful` counts
 * only pages that produced a usable result — so cost/page honestly includes
 * retry overhead, the exact thing the pricing model had to guess at.
 */
export async function logMarkingUsage(db: Firestore, rec: UsageRecord): Promise<void> {
  const batch = db.batch();
  batch.set(db.collection("markingUsage").doc(), { ...rec, at: Timestamp.fromMillis(rec.atMs) });
  batch.set(
    db.collection("ownerData").doc("usageAgg"),
    {
      engines: {
        [rec.engine]: {
          attempts: FieldValue.increment(1),
          successes: FieldValue.increment(rec.ok ? 1 : 0),
          pagesSuccessful: FieldValue.increment(rec.ok ? rec.pages : 0),
          costUsd: FieldValue.increment(rec.costUsd ?? 0),
          unpricedAttempts: FieldValue.increment(rec.costUsd === null ? 1 : 0),
          promptTokens: FieldValue.increment(rec.promptTokens),
          outputTokens: FieldValue.increment(rec.outputTokens),
          thinkingTokens: FieldValue.increment(rec.thinkingTokens),
          imageTokens: FieldValue.increment(rec.imageTokens),
        },
      },
      updatedAt: Timestamp.fromMillis(rec.atMs),
    },
    { merge: true }
  );
  await batch.commit();
}
