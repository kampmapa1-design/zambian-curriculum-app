// Emulator test for the CDC crawl spend guard: only ONE of many concurrent
// callers may start a crawl, and failures back the next attempt off.
import * as admin from "firebase-admin";
import { CDC_CACHE_STALE_MS, CDC_MIN_ATTEMPT_GAP_MS, HOUR_MS, claimCdcCrawl, decideCdcServe, finishCdcCrawl } from "./cdcGuard";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error("Refusing to run: FIRESTORE_EMULATOR_HOST is not set. Use `npm run test:int` (it starts the emulator).");
}
admin.initializeApp({ projectId: "cdc-guard-int-test" });
const db = admin.firestore();
const NOW = Date.parse("2026-09-19T10:00:00Z");

beforeEach(async () => {
  await db.collection("system").doc("cdcRefreshGuard").delete();
});

describe("claimCdcCrawl", () => {
  test("of 12 simultaneous callers exactly ONE wins the crawl", async () => {
    const results = await Promise.all(Array.from({ length: 12 }, () => claimCdcCrawl(db, NOW)));
    expect(results.filter(Boolean)).toHaveLength(1);
  });

  test("while the winner is crawling, later callers are refused", async () => {
    expect(await claimCdcCrawl(db, NOW)).toBe(true);
    expect(await claimCdcCrawl(db, NOW + 1000)).toBe(false);
  });

  test("after a successful crawl there is still the 6-hour gap", async () => {
    await claimCdcCrawl(db, NOW);
    await finishCdcCrawl(db, NOW + 30_000, null);
    expect(await claimCdcCrawl(db, NOW + HOUR_MS)).toBe(false);
    expect(await claimCdcCrawl(db, NOW + CDC_MIN_ATTEMPT_GAP_MS + 1)).toBe(true);
  });

  test("a FAILED crawl is remembered and backs off: 12h after one failure, 24h after two", async () => {
    await claimCdcCrawl(db, NOW);
    await finishCdcCrawl(db, NOW + 30_000, "RESOURCE_EXHAUSTED");
    expect(await claimCdcCrawl(db, NOW + 11 * HOUR_MS)).toBe(false);
    const secondAt = NOW + 12 * HOUR_MS;
    expect(await claimCdcCrawl(db, secondAt)).toBe(true);
    await finishCdcCrawl(db, secondAt + 30_000, "RESOURCE_EXHAUSTED");
    expect(await claimCdcCrawl(db, secondAt + 23 * HOUR_MS)).toBe(false);
    expect(await claimCdcCrawl(db, secondAt + 24 * HOUR_MS)).toBe(true);
    const state = (await db.collection("system").doc("cdcRefreshGuard").get()).data();
    expect(state?.consecutiveFailures).toBe(2);
    expect(state?.lastError).toBe("RESOURCE_EXHAUSTED");
  });

  test("a success clears the failure streak", async () => {
    await claimCdcCrawl(db, NOW);
    await finishCdcCrawl(db, NOW + 1000, "boom");
    const t = NOW + 12 * HOUR_MS;
    await claimCdcCrawl(db, t);
    await finishCdcCrawl(db, t + 1000, null);
    const state = (await db.collection("system").doc("cdcRefreshGuard").get()).data();
    expect(state?.consecutiveFailures).toBe(0);
    expect(state?.lastError).toBeNull();
  });
});

describe("decideCdcServe", () => {
  test("a fresh cache is served with no crawl and no guard write", async () => {
    expect(await decideCdcServe(db, NOW - HOUR_MS, NOW)).toBe("serve-cache");
    expect((await db.collection("system").doc("cdcRefreshGuard").get()).exists).toBe(false);
  });

  test("a stale cache triggers ONE crawl; every other simultaneous caller is served the stale copy", async () => {
    const staleAt = NOW - CDC_CACHE_STALE_MS - HOUR_MS;
    const decisions = await Promise.all(Array.from({ length: 10 }, () => decideCdcServe(db, staleAt, NOW)));
    expect(decisions.filter((d) => d === "crawl")).toHaveLength(1);
    expect(decisions.filter((d) => d === "serve-stale")).toHaveLength(9);
  });

  test("no cache at all and a crawl already running: the caller gets 'unavailable', not a second crawl", async () => {
    expect(await decideCdcServe(db, null, NOW)).toBe("crawl");
    expect(await decideCdcServe(db, null, NOW + 1000)).toBe("unavailable");
  });

  test("a broken crawl cannot be re-triggered by hammering it: 500 callers after a failure start zero crawls", async () => {
    const staleAt = NOW - CDC_CACHE_STALE_MS - HOUR_MS;
    expect(await decideCdcServe(db, staleAt, NOW)).toBe("crawl");
    await finishCdcCrawl(db, NOW + 5000, "quota");
    const later = await Promise.all(Array.from({ length: 500 }, (_, i) => decideCdcServe(db, staleAt, NOW + HOUR_MS + i)));
    expect(later.filter((d) => d === "crawl")).toHaveLength(0);
  });
});
