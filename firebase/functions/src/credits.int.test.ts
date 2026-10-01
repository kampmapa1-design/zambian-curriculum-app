// Integration tests for the money-critical, transactional half of the credit
// system, run against the LOCAL Firestore emulator (npm run test:int).
// These prove the properties that matter when credits cost real money:
//   * a script is never charged twice, however many times a request repeats
//   * a re-delivered purchase receipt never credits twice
//   * parallel requests cannot lose an update
//   * a balance can never go negative
//   * shadow/off modes never touch a balance
import * as admin from "firebase-admin";
import {
  DEFAULT_MARKING_CREDITS_CONFIG,
  chargeSuccessfulMarking,
  checkCanAfford,
  grantPurchase,
  hashId,
  userOwnerKey,
  type MarkingCreditsConfig,
} from "./credits";
import { logMarkingUsage } from "./usageLog";
import { recordRevenueEvent, updateRevenueSummary, DAY_MS } from "./revenue";

// Refuse to run against anything but the emulator — these tests write and delete.
if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error("Refusing to run: FIRESTORE_EMULATOR_HOST is not set. Use `npm run test:int` (it starts the emulator).");
}
admin.initializeApp({ projectId: "credits-int-test" });
const db = admin.firestore();

const NOW = Date.parse("2026-09-19T10:00:00Z");
// The allowance is pinned at 20 here so these tests exercise the ledger arithmetic
// independently of the product default (10) — the default has its own test below.
const cfgWith = (mode: MarkingCreditsConfig["mode"]): MarkingCreditsConfig => ({
  ...JSON.parse(JSON.stringify(DEFAULT_MARKING_CREDITS_CONFIG)),
  mode,
  freeMonthlyCredits: 20,
});

let counter = 0;
const newUser = () => {
  const uid = `int-user-${Date.now()}-${counter++}`;
  return { uid, key: userOwnerKey(uid) };
};
const charge = (
  u: { uid: string; key: string },
  o: Partial<{ engine: "stable" | "concise" | "keyed"; pages: number; requestId: string; mode: MarkingCreditsConfig["mode"]; nowMs: number }> = {}
) =>
  chargeSuccessfulMarking(db, {
    ownerKey: u.key, ownerId: u.uid, ownerType: "user", engine: o.engine ?? "concise", pages: o.pages ?? 4,
    requestId: o.requestId, cfg: cfgWith(o.mode ?? "enforced"), nowMs: o.nowMs ?? NOW, fn: "concise",
  });
const ledger = async (key: string) => (await db.collection("creditLedgers").doc(key).get()).data();
const txns = async (key: string) =>
  (await db.collection("creditLedgers").doc(key).collection("transactions").get()).docs.map((d) => d.data());

async function wipe(collection: string) {
  const snap = await db.collection(collection).get();
  await Promise.all(snap.docs.map((d) => d.ref.delete()));
}

describe("chargeSuccessfulMarking — enforced", () => {
  test("first charge grants the free allowance, then spends from it: 20 - 12.8 = 7.2 credits left", async () => {
    const u = newUser();
    const r = await charge(u); // 4 concise pages x 3.2 = 12.8
    expect(r.charged).toBe(true);
    expect(r.units).toBe(12_800);
    const l = await ledger(u.key);
    expect(l?.freeUnits).toBe(7_200);
    expect(l?.purchasedUnits).toBe(0);
    expect(l?.freePeriod).toBe("2026-09");
    const types = (await txns(u.key)).map((t) => t.type).sort();
    expect(types).toEqual(["free_grant", "spend"]);
  });

  test("the SAME requestId charges exactly once, however many times it repeats", async () => {
    const u = newUser();
    const first = await charge(u, { requestId: "script-1-attempt-A" });
    const again = await charge(u, { requestId: "script-1-attempt-A" });
    const thrice = await charge(u, { requestId: "script-1-attempt-A" });
    expect(first.charged).toBe(true);
    expect(again.duplicate).toBe(true);
    expect(again.charged).toBe(false);
    expect(thrice.duplicate).toBe(true);
    expect((await ledger(u.key))?.freeUnits).toBe(7_200); // charged once only
    expect((await txns(u.key)).filter((t) => t.type === "spend")).toHaveLength(1);
  });

  test("different requestIds (two genuine markings) are both charged", async () => {
    const u = newUser();
    await charge(u, { requestId: "a", engine: "stable", pages: 4 });
    await charge(u, { requestId: "b", engine: "stable", pages: 4 });
    expect((await ledger(u.key))?.freeUnits).toBe(12_000); // 20 - 4 - 4
  });

  test("no requestId (an older app build): every call charges", async () => {
    const u = newUser();
    await charge(u, { engine: "stable", pages: 2 });
    await charge(u, { engine: "stable", pages: 2 });
    expect((await ledger(u.key))?.freeUnits).toBe(16_000);
  });

  test("engine weights apply: 4 pages of Stable = 4 credits, Key-based = 13.2", async () => {
    const s = newUser();
    const k = newUser();
    expect((await charge(s, { engine: "stable" })).units).toBe(4_000);
    expect((await charge(k, { engine: "keyed" })).units).toBe(13_200);
  });

  test("the 2027 weights are used once SERVER time passes 1 Jan 2027 (Concise 6.4/page)", async () => {
    const u = newUser();
    // Enough purchased balance that the full 25.6 can be charged (a fresh user's 20 free would cap it).
    await db.collection("creditLedgers").doc(u.key).set({ ownerType: "user", ownerId: u.uid, purchasedUnits: 100_000, freeUnits: 0, freePeriod: "2027-01" });
    const r = await charge(u, { nowMs: Date.parse("2027-01-01T00:00:00+02:00") });
    expect(r.units).toBe(25_600); // 4 x 6.4
    expect(r.shortfallUnits).toBe(0);
    // ...and one millisecond earlier it is still the 2026 price (4 x 3.2).
    const v = newUser();
    await db.collection("creditLedgers").doc(v.key).set({ ownerType: "user", ownerId: v.uid, purchasedUnits: 100_000, freeUnits: 0, freePeriod: "2026-12" });
    expect((await charge(v, { nowMs: Date.parse("2027-01-01T00:00:00+02:00") - 1 })).units).toBe(12_800);
  });

  test("a balance can never go negative: an overdraw is capped and the shortfall recorded", async () => {
    const u = newUser();
    await db.collection("creditLedgers").doc(u.key).set({
      ownerType: "user", ownerId: u.uid, purchasedUnits: 2_000, freeUnits: 1_000, freePeriod: "2026-09",
    });
    const r = await charge(u); // needs 12.8 but only 3.0 exists
    expect(r.shortfallUnits).toBe(9_800);
    const l = await ledger(u.key);
    expect(l?.freeUnits).toBe(0);
    expect(l?.purchasedUnits).toBe(0);
  });

  test("free credits are spent BEFORE purchased ones", async () => {
    const u = newUser();
    await db.collection("creditLedgers").doc(u.key).set({
      ownerType: "user", ownerId: u.uid, purchasedUnits: 50_000, freeUnits: 5_000, freePeriod: "2026-09",
    });
    await charge(u, { engine: "stable", pages: 8 }); // 8 credits: 5 free + 3 purchased
    const l = await ledger(u.key);
    expect(l?.freeUnits).toBe(0);
    expect(l?.purchasedUnits).toBe(47_000);
  });

  test("a new month expires unused free credits (no roll-over) and leaves purchased credits alone", async () => {
    const u = newUser();
    await db.collection("creditLedgers").doc(u.key).set({
      ownerType: "user", ownerId: u.uid, purchasedUnits: 50_000, freeUnits: 5_000, freePeriod: "2026-08",
    });
    await charge(u, { engine: "stable", pages: 1 });
    const l = await ledger(u.key);
    expect(l?.freeUnits).toBe(19_000); // fresh 20, minus 1 — NOT 25
    expect(l?.purchasedUnits).toBe(50_000);
    const grant = (await txns(u.key)).find((t) => t.type === "free_grant");
    expect(grant?.expiredUnits).toBe(5_000);
  });

  test("parallel charges with distinct ids never lose an update (10 x 1 credit from 20 free = 10 left)", async () => {
    const u = newUser();
    await Promise.all(Array.from({ length: 10 }, (_, i) => charge(u, { engine: "stable", pages: 1, requestId: `p-${i}` })));
    expect((await ledger(u.key))?.freeUnits).toBe(10_000);
  });

  test("parallel charges with the SAME id charge exactly once", async () => {
    const u = newUser();
    const results = await Promise.all(Array.from({ length: 8 }, () => charge(u, { engine: "stable", pages: 1, requestId: "same" })));
    expect(results.filter((r) => r.charged)).toHaveLength(1);
    expect((await ledger(u.key))?.freeUnits).toBe(19_000);
  });
});

describe("the shipped default allowance", () => {
  test("a brand-new teacher on the DEFAULT config is granted exactly 10 free credits, and a 4-page Concise script (12.8) is capped, not overdrawn", async () => {
    const u = newUser();
    const cfg = { ...JSON.parse(JSON.stringify(DEFAULT_MARKING_CREDITS_CONFIG)), mode: "enforced" as const };
    expect(cfg.freeMonthlyCredits).toBe(10);
    const r = await chargeSuccessfulMarking(db, {
      ownerKey: u.key, ownerId: u.uid, ownerType: "user", engine: "stable", pages: 4, cfg, nowMs: NOW, fn: "concise",
    });
    expect(r.units).toBe(4_000);
    expect((await ledger(u.key))?.freeUnits).toBe(6_000); // 10 - 4
    const c = await checkCanAfford(db, newUser().key, cfg, "concise", 4, NOW);
    expect(c.availableUnits).toBe(10_000);
    expect(c.ok).toBe(false); // 12.8 > 10: a new teacher's first 4-page Concise script needs a bundle
  });
});

describe("modes that must not touch a balance", () => {
  test("OFF: nothing is written at all", async () => {
    const u = newUser();
    const r = await charge(u, { mode: "off" });
    expect(r.charged).toBe(false);
    expect(await ledger(u.key)).toBeUndefined();
    expect(await txns(u.key)).toHaveLength(0);
  });

  test("SHADOW: records what WOULD be charged, changes no balance, creates no ledger", async () => {
    const u = newUser();
    const r = await charge(u, { mode: "shadow" });
    expect(r.charged).toBe(false);
    expect(r.units).toBe(12_800);
    expect(await ledger(u.key)).toBeUndefined();
    const t = await txns(u.key);
    expect(t).toHaveLength(1);
    expect(t[0].type).toBe("shadow_spend");
  });

  test("SHADOW is idempotent per requestId too", async () => {
    const u = newUser();
    await charge(u, { mode: "shadow", requestId: "x" });
    await charge(u, { mode: "shadow", requestId: "x" });
    expect(await txns(u.key)).toHaveLength(1);
  });
});

describe("checkCanAfford (the pre-check before the paid AI call)", () => {
  test("only bites in enforced mode", async () => {
    const u = newUser();
    expect((await checkCanAfford(db, u.key, cfgWith("off"), "concise", 400, NOW)).ok).toBe(true);
    expect((await checkCanAfford(db, u.key, cfgWith("shadow"), "concise", 400, NOW)).ok).toBe(true);
    expect((await checkCanAfford(db, u.key, cfgWith("enforced"), "concise", 400, NOW)).ok).toBe(false);
  });

  test("a brand-new user counts the free allowance they WILL be granted, so their first script isn't refused", async () => {
    const u = newUser();
    const c = await checkCanAfford(db, u.key, cfgWith("enforced"), "concise", 4, NOW);
    expect(c.ok).toBe(true); // needs 12.8, has 20 free
    expect(c.availableUnits).toBe(20_000);
    expect(await ledger(u.key)).toBeUndefined(); // the check itself wrote nothing
  });

  test("insufficient balance is reported with the amounts", async () => {
    const u = newUser();
    await db.collection("creditLedgers").doc(u.key).set({ ownerType: "user", ownerId: u.uid, purchasedUnits: 0, freeUnits: 2_000, freePeriod: "2026-09" });
    const c = await checkCanAfford(db, u.key, cfgWith("enforced"), "concise", 4, NOW);
    expect(c.ok).toBe(false);
    expect(c.needUnits).toBe(12_800);
    expect(c.availableUnits).toBe(2_000);
  });
});

describe("grantPurchase — idempotent per purchase", () => {
  const grant = (u: { uid: string; key: string }, purchaseKey: string, credits = 87) =>
    grantPurchase(db, { ownerKey: u.key, ownerId: u.uid, ownerType: "user", purchaseKey, productId: "marking_bundle_k50", credits, orderId: "GPA.1234", nowMs: NOW });

  test("credits the bundle once", async () => {
    const u = newUser();
    const r = await grant(u, hashId(`tok-${u.uid}`));
    expect(r.duplicate).toBe(false);
    expect(r.creditsGranted).toBe(87);
    expect((await ledger(u.key))?.purchasedUnits).toBe(87_000);
    expect((await txns(u.key)).filter((t) => t.type === "purchase")).toHaveLength(1);
  });

  test("a re-delivered receipt (same token) NEVER credits twice — sequential or parallel", async () => {
    const u = newUser();
    const key = hashId(`tok-${u.uid}`);
    await grant(u, key);
    const again = await grant(u, key);
    expect(again.duplicate).toBe(true);
    await Promise.all(Array.from({ length: 6 }, () => grant(u, key)));
    expect((await ledger(u.key))?.purchasedUnits).toBe(87_000);
  });

  test("two DIFFERENT purchases both credit", async () => {
    const u = newUser();
    await grant(u, hashId(`a-${u.uid}`), 87);
    await grant(u, hashId(`b-${u.uid}`), 178);
    expect((await ledger(u.key))?.purchasedUnits).toBe(265_000);
  });

  test("a purchase then marking: free credits are used first, purchased credits survive", async () => {
    const u = newUser();
    await grant(u, hashId(`tok-${u.uid}`));
    await charge(u, { engine: "stable", pages: 4 });
    const l = await ledger(u.key);
    expect(l?.purchasedUnits).toBe(87_000);
    expect(l?.freeUnits).toBe(16_000);
  });
});

describe("revenue tracking", () => {
  beforeEach(async () => {
    await wipe("revenueEvents");
    await db.collection("ownerData").doc("revenue").delete();
  });
  const ev = (key: string, amount: number, atMs: number) => ({ eventKey: key, amountKwacha: amount, productId: "marking_bundle_k100", atMs, orderId: null });

  test("a repeated purchase is counted once", async () => {
    expect(await recordRevenueEvent(db, ev("p1", 100, NOW))).toBe(true);
    expect(await recordRevenueEvent(db, ev("p1", 100, NOW))).toBe(false);
    const s = await updateRevenueSummary(db, NOW, 800_000);
    expect(s.rolling12mKwacha).toBe(100);
    expect(s.eventCount).toBe(1);
  });

  test("the rolling window drops events older than 365 days", async () => {
    await recordRevenueEvent(db, ev("old", 500, NOW - 366 * DAY_MS));
    await recordRevenueEvent(db, ev("recent", 300, NOW - 10 * DAY_MS));
    expect((await updateRevenueSummary(db, NOW, 800_000)).rolling12mKwacha).toBe(300);
  });

  test("crossing the threshold flags once (crossedNow true exactly one time) and the flag is sticky", async () => {
    await recordRevenueEvent(db, ev("a", 500_000, NOW - 5 * DAY_MS));
    expect((await updateRevenueSummary(db, NOW, 800_000)).vatThresholdCrossed).toBe(false);

    await recordRevenueEvent(db, ev("b", 350_000, NOW - DAY_MS));
    const crossed = await updateRevenueSummary(db, NOW, 800_000);
    expect(crossed.vatThresholdCrossed).toBe(true);
    expect(crossed.crossedNow).toBe(true);
    expect(crossed.rolling12mKwacha).toBe(850_000);

    const later = await updateRevenueSummary(db, NOW + DAY_MS, 800_000);
    expect(later.crossedNow).toBe(false); // already flagged — the owner is not re-notified
    expect(later.vatThresholdCrossed).toBe(true);

    // A year on, the revenue has aged out of the window, but registration doesn't un-happen.
    const muchLater = await updateRevenueSummary(db, NOW + 400 * DAY_MS, 800_000);
    expect(muchLater.rolling12mKwacha).toBe(0);
    expect(muchLater.vatThresholdCrossed).toBe(true);
  });
});

describe("usage logging", () => {
  beforeEach(async () => {
    await db.collection("ownerData").doc("usageAgg").delete();
  });
  const rec = (ok: boolean, pages: number, cost: number | null) => ({
    fn: "concise", engine: "concise" as const, model: "gemini-3.6-flash", pages, questionCount: 8, attempt: 1, ok, finishReason: "STOP",
    promptTokens: 1000, outputTokens: 500, thinkingTokens: 200, imageTokens: 400, totalTokens: 1700, costUsd: cost,
    uidHash: "abc", requestId: null, atMs: NOW,
  });

  test("records each attempt and keeps honest running totals — a failed retry costs money but adds no pages", async () => {
    await logMarkingUsage(db, rec(false, 4, 0.01)); // a failed attempt
    await logMarkingUsage(db, rec(true, 4, 0.02)); // the retry that worked
    const agg = (await db.collection("ownerData").doc("usageAgg").get()).data();
    const e = agg?.engines?.concise;
    expect(e.attempts).toBe(2);
    expect(e.successes).toBe(1);
    expect(e.pagesSuccessful).toBe(4);
    expect(e.costUsd).toBeCloseTo(0.03, 8);
    // measured cost per page = 0.03 / 4 = $0.0075 — the retry overhead is INCLUDED, which is the point.
    expect(e.costUsd / e.pagesSuccessful).toBeCloseTo(0.0075, 8);
    expect(e.thinkingTokens).toBe(400);
  });

  test("an unpriced model is counted separately instead of silently costing zero", async () => {
    await logMarkingUsage(db, rec(true, 4, null));
    const e = (await db.collection("ownerData").doc("usageAgg").get()).data()?.engines?.concise;
    expect(e.unpricedAttempts).toBe(1);
    expect(e.costUsd).toBe(0);
  });
});
