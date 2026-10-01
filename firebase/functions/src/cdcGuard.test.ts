import {
  CDC_CACHE_STALE_MS,
  CDC_LEASE_MS,
  CDC_MAX_BACKOFF_MS,
  CDC_MIN_ATTEMPT_GAP_MS,
  HOUR_MS,
  attemptGapMs,
  cacheIsFresh,
  canStartCrawl,
  emptyGuardState,
  parseGuardState,
} from "./cdcGuard";

const NOW = Date.parse("2026-09-19T10:00:00Z");

describe("attemptGapMs — failures back the crawl off, exponentially, to a cap", () => {
  test("6h, 12h, 24h, then capped at 48h", () => {
    expect(attemptGapMs(0)).toBe(6 * HOUR_MS);
    expect(attemptGapMs(1)).toBe(12 * HOUR_MS);
    expect(attemptGapMs(2)).toBe(24 * HOUR_MS);
    expect(attemptGapMs(3)).toBe(CDC_MAX_BACKOFF_MS);
    expect(attemptGapMs(50)).toBe(CDC_MAX_BACKOFF_MS);
  });
  test("a nonsense failure count never shortens the gap", () => {
    expect(attemptGapMs(-4)).toBe(CDC_MIN_ATTEMPT_GAP_MS);
  });
});

describe("canStartCrawl", () => {
  test("a fresh system (never crawled) may crawl", () => {
    expect(canStartCrawl(emptyGuardState(), NOW)).toBe(true);
  });

  test("while a crawl holds the lease NOBODY else may start one", () => {
    const s = { ...emptyGuardState(), lastAttemptAtMs: NOW - 60_000, leaseUntilMs: NOW + 5 * 60_000 };
    expect(canStartCrawl(s, NOW)).toBe(false);
  });

  test("a crashed crawl frees itself when its lease runs out — but the attempt gap still applies", () => {
    const crashed = { ...emptyGuardState(), lastAttemptAtMs: NOW - CDC_LEASE_MS - 1, leaseUntilMs: NOW - 1 };
    expect(canStartCrawl(crashed, NOW)).toBe(false); // lease expired, but only 10 minutes since the attempt
    expect(canStartCrawl(crashed, NOW + CDC_MIN_ATTEMPT_GAP_MS)).toBe(true);
  });

  test("after a SUCCESS there is still a 6-hour gap (a stampede of cache-miss callers cannot chain crawls)", () => {
    const s = { ...emptyGuardState(), lastAttemptAtMs: NOW - HOUR_MS };
    expect(canStartCrawl(s, NOW)).toBe(false);
    expect(canStartCrawl(s, NOW + 5 * HOUR_MS)).toBe(true);
  });

  test("after repeated FAILURES the gap grows — the failed-crawl retry storm cannot happen", () => {
    const s = { ...emptyGuardState(), lastAttemptAtMs: NOW, consecutiveFailures: 3 };
    expect(canStartCrawl(s, NOW + 47 * HOUR_MS)).toBe(false);
    expect(canStartCrawl(s, NOW + 48 * HOUR_MS)).toBe(true);
  });

  test("simulated storm: 1,000 callers over a day against a permanently failing crawl allow at most 3 attempts", () => {
    let state = emptyGuardState();
    let attempts = 0;
    for (let i = 0; i < 1000; i++) {
      const t = NOW + Math.floor((i / 1000) * 24 * HOUR_MS);
      if (canStartCrawl(state, t)) {
        attempts++;
        state = { lastAttemptAtMs: t, leaseUntilMs: null, consecutiveFailures: state.consecutiveFailures + 1, lastError: "quota" };
      }
    }
    expect(attempts).toBeLessThanOrEqual(3);
    expect(attempts).toBeGreaterThanOrEqual(1);
  });
});

describe("cacheIsFresh", () => {
  test("fresh under 10 days, stale after; a missing cache is never fresh", () => {
    expect(cacheIsFresh(NOW - CDC_CACHE_STALE_MS + 1, NOW)).toBe(true);
    expect(cacheIsFresh(NOW - CDC_CACHE_STALE_MS, NOW)).toBe(false);
    expect(cacheIsFresh(null, NOW)).toBe(false);
  });
});

describe("parseGuardState", () => {
  test("garbage or missing state falls back to a clean slate", () => {
    expect(parseGuardState(undefined)).toEqual(emptyGuardState());
    expect(parseGuardState({ lastAttemptAtMs: "soon", consecutiveFailures: -5, lastError: 7 })).toEqual(emptyGuardState());
  });
});
