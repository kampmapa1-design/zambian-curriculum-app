// Integration tests (local Firestore emulator) for the owner-only finance tools.
// (Buying credits is covered stage by stage in purchases.int.test.ts.)
import * as admin from "firebase-admin";
import { hashId } from "./credits";
import { resetBillingCaches } from "./markingBilling";
import { getFinanceSummary, obfuscatedAccountId, setExchangeRate } from "./monetization";
import { DAY_MS } from "./revenue";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error("Refusing to run: FIRESTORE_EMULATOR_HOST is not set. Use `npm run test:int` (it starts the emulator).");
}
admin.initializeApp({ projectId: "monetization-int-test" });
const db = admin.firestore();
const NOW = Date.parse("2026-09-19T10:00:00Z");



async function wipe(collection: string) {
  const snap = await db.collection(collection).get();
  await Promise.all(snap.docs.map((d) => d.ref.delete()));
}

beforeEach(async () => {
  resetBillingCaches();
  await Promise.all([wipe("revenueEvents"), wipe("appConfig")]);
  await db.collection("ownerData").doc("revenue").delete();
  await db.collection("ownerData").doc("settings").delete();
});

describe("owner-only tools", () => {
  const ownerUid = "owner-uid-1";
  beforeEach(async () => {
    await db.collection("ownerData").doc("settings").set({ ownerUids: [ownerUid], ownerEmail: "owner@example.com" });
    await db.collection("ownerData").doc("usageAgg").delete();
  });

  test("a non-owner (or signed-out caller) cannot read the finance summary or change the exchange rate", async () => {
    await expect(getFinanceSummary(db, "someone-else", NOW)).rejects.toMatchObject({ code: "permission-denied" });
    await expect(getFinanceSummary(db, undefined, NOW)).rejects.toMatchObject({ code: "unauthenticated" });
    await expect(setExchangeRate(db, "someone-else", 25, NOW)).rejects.toMatchObject({ code: "permission-denied" });
    expect((await db.collection("ownerData").doc("settings").get()).data()?.fxUsdToZmw).toBeUndefined();
  });

  test("the owner sees revenue, distance to the threshold, measured-vs-modelled cost and the active config", async () => {
    await db.collection("ownerData").doc("revenue").set({ rolling12mKwacha: 200_000, vatThresholdCrossed: false, updatedAtMs: NOW });
    await db.collection("ownerData").doc("usageAgg").set({ engines: { concise: { attempts: 10, successes: 8, pagesSuccessful: 32, costUsd: 0.4, thinkingTokens: 5000 } } });
    const s = await getFinanceSummary(db, ownerUid, NOW);
    expect(s.revenue).toMatchObject({ rolling12mKwacha: 200_000, thresholdKwacha: 800_000, remainingKwacha: 600_000, vatThresholdCrossed: false });
    expect(s.revenue.percentOfThreshold).toBeCloseTo(25, 5);
    expect(s.usage.concise.measuredCostPerPageUsd).toBeCloseTo(0.0125, 8); // 0.4 / 32 — retries included
    expect(s.usage.concise.measuredVsModeled).toBeCloseTo(0.0125 / 0.0083, 5);
    expect(s.usage.stable.measuredCostPerPageUsd).toBeNull(); // no data yet — never a fake zero
    expect(s.config.activeWeights).toMatchObject({ stable: 1, concise: 3.2, keyed: 3.3 });
    expect(s.config.nextWeights).toMatchObject({ concise: 6.4, keyed: 6.5 });
    expect(Object.keys(s.config.bundles)).toEqual(["marking_bundle_k50", "marking_bundle_k100", "marking_bundle_k150"]);
  });

  test("exchange rate: never-set is flagged stale; updating stamps the time and clears it; >60 days is stale again", async () => {
    let s = await getFinanceSummary(db, ownerUid, NOW);
    expect(s.fx).toMatchObject({ rate: 20, updatedAtMs: null, stale: true });

    const updated = await setExchangeRate(db, ownerUid, 24.5, NOW);
    expect(updated).toMatchObject({ rate: 24.5, updatedAtMs: NOW, daysSinceUpdate: 0, stale: false });
    // ownerUids survived the update (merge, not overwrite)
    expect((await db.collection("ownerData").doc("settings").get()).data()?.ownerUids).toEqual([ownerUid]);

    s = await getFinanceSummary(db, ownerUid, NOW + 60 * DAY_MS);
    expect(s.fx.stale).toBe(false); // exactly 60 days: not yet
    s = await getFinanceSummary(db, ownerUid, NOW + 61 * DAY_MS);
    expect(s.fx).toMatchObject({ daysSinceUpdate: 61, stale: true });
  });

  test("exchange rate input is validated", async () => {
    for (const bad of [0, -3, NaN, Infinity, "24", null, 5000]) {
      await expect(setExchangeRate(db, ownerUid, bad, NOW)).rejects.toMatchObject({ code: "invalid-argument" });
    }
  });
});

test("hashed account ids are stable, never the raw uid, and Play-sized (<= 64 chars)", () => {
  const id = obfuscatedAccountId("abc123");
  expect(id).toBe(obfuscatedAccountId("abc123"));
  expect(id).not.toContain("abc123");
  expect(id.length).toBeLessThanOrEqual(64);
  expect(hashId("x")).not.toBe(id);
});
