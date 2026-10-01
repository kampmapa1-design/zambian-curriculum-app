// Spend guard for the CDC catalogue crawl (added 2026-09-19).
//
// The crawl is two Gemini calls with googleSearch + urlContext grounding — by
// far the most expensive thing in the backend per call, and it once drained a
// prepaid balance in four days (~30 crawls a day, see the billing notes).
// The 2026-09-15 fix made a weekly schedule do the real work and gave the
// callable a 24h cache, but left an emergency fallback: if the cache was
// missing or older than 10 days, EVERY call from EVERY signed-in user (a
// throwaway anonymous account is enough) ran a fresh crawl — with no lock, no
// memory of failures, and no rate limit. A failed weekly run (an empty Gemini
// balance is enough) would therefore turn straight back into a crawl storm.
//
// This guard makes a crawl a rationed, single-flight, failure-aware event:
//  * at most ONE crawl in flight worldwide (a lease),
//  * a minimum gap between attempts, growing exponentially after each failure,
//  * failures are remembered, so a broken or quota-exhausted crawl is not
//    retried by every caller,
//  * callers who are refused a crawl are served the last cached catalogue,
//    however old, rather than an error.
import type { Firestore } from "firebase-admin/firestore";
import { Timestamp } from "firebase-admin/firestore";

export const HOUR_MS = 60 * 60 * 1000;
/** Minimum gap between crawl attempts, success or not. */
export const CDC_MIN_ATTEMPT_GAP_MS = 6 * HOUR_MS;
/** After repeated failures the gap doubles each time, up to this cap. */
export const CDC_MAX_BACKOFF_MS = 48 * HOUR_MS;
/** How long one crawl may hold the lease before another is allowed (a crashed run frees itself). */
export const CDC_LEASE_MS = 10 * 60 * 1000;
/** A cache older than this is worth an emergency crawl (the weekly schedule has missed two cycles). */
export const CDC_CACHE_STALE_MS = 10 * 24 * HOUR_MS;

export interface CdcGuardState {
  lastAttemptAtMs: number | null;
  leaseUntilMs: number | null;
  consecutiveFailures: number;
  lastError: string | null;
}

export const emptyGuardState = (): CdcGuardState => ({ lastAttemptAtMs: null, leaseUntilMs: null, consecutiveFailures: 0, lastError: null });

export function parseGuardState(d: Record<string, unknown> | undefined): CdcGuardState {
  const n = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
  return {
    lastAttemptAtMs: n(d?.lastAttemptAtMs),
    leaseUntilMs: n(d?.leaseUntilMs),
    consecutiveFailures: Math.max(0, n(d?.consecutiveFailures) ?? 0),
    lastError: typeof d?.lastError === "string" ? d.lastError : null,
  };
}

/** The wait after the last attempt before another is allowed: 6h, doubling per consecutive failure, capped at 48h. */
export function attemptGapMs(consecutiveFailures: number): number {
  return Math.min(CDC_MAX_BACKOFF_MS, CDC_MIN_ATTEMPT_GAP_MS * 2 ** Math.max(0, consecutiveFailures));
}

/** Pure: may a crawl start now? */
export function canStartCrawl(state: CdcGuardState, nowMs: number): boolean {
  if (state.leaseUntilMs !== null && nowMs < state.leaseUntilMs) return false; // another crawl is in flight
  if (state.lastAttemptAtMs !== null && nowMs < state.lastAttemptAtMs + attemptGapMs(state.consecutiveFailures)) return false;
  return true;
}

/** Pure: is a cache fresh enough to serve without any crawl? */
export const cacheIsFresh = (fetchedAtMs: number | null, nowMs: number): boolean =>
  fetchedAtMs !== null && nowMs - fetchedAtMs < CDC_CACHE_STALE_MS;

const guardRef = (db: Firestore) => db.collection("system").doc("cdcRefreshGuard");

/**
 * Atomically claim the right to run ONE crawl. Only one caller can win: the
 * winner's lease blocks everyone else until it finishes (or 10 minutes pass).
 */
export async function claimCdcCrawl(db: Firestore, nowMs: number): Promise<boolean> {
  return db.runTransaction(async (tx) => {
    const state = parseGuardState((await tx.get(guardRef(db))).data());
    if (!canStartCrawl(state, nowMs)) return false;
    tx.set(guardRef(db), { lastAttemptAtMs: nowMs, leaseUntilMs: nowMs + CDC_LEASE_MS, updatedAt: Timestamp.fromMillis(nowMs) }, { merge: true });
    return true;
  });
}

/** Record how a claimed crawl ended: success resets the backoff; failure lengthens it. */
export async function finishCdcCrawl(db: Firestore, nowMs: number, error: string | null): Promise<void> {
  await db.runTransaction(async (tx) => {
    const state = parseGuardState((await tx.get(guardRef(db))).data());
    tx.set(
      guardRef(db),
      {
        leaseUntilMs: null,
        consecutiveFailures: error === null ? 0 : state.consecutiveFailures + 1,
        lastError: error === null ? null : error.slice(0, 300),
        updatedAt: Timestamp.fromMillis(nowMs),
      },
      { merge: true }
    );
  });
}

export type CdcServeDecision = "serve-cache" | "crawl" | "serve-stale" | "unavailable";

/**
 * What the callable should do for one request, claiming the crawl lease when
 * (and only when) a crawl is genuinely allowed.
 */
export async function decideCdcServe(
  db: Firestore,
  cacheFetchedAtMs: number | null,
  nowMs: number
): Promise<CdcServeDecision> {
  if (cacheIsFresh(cacheFetchedAtMs, nowMs)) return "serve-cache";
  if (await claimCdcCrawl(db, nowMs)) return "crawl";
  return cacheFetchedAtMs !== null ? "serve-stale" : "unavailable";
}
