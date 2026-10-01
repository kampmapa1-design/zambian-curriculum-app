// Emulator tests for metering every non-marking AI feature and for ad passes.
// The properties that matter when a generation costs real money:
//   * nothing is charged unless the generation SUCCEEDED, and only once
//   * a refused request never reaches the (paid) AI call
//   * off / shadow never touch a balance; features and marking switch independently
//   * an ad pass pays for exactly one generation and can't be forged, reused,
//     borrowed from another teacher, or used after it expires
import * as admin from "firebase-admin";
import type { GoogleGenAI } from "@google/genai";
import type { CallableRequest } from "firebase-functions/v2/https";
import { generateTracked } from "./aiUsage";
import { DEFAULT_MARKING_CREDITS_CONFIG, hashId } from "./credits";
import { grantAdPass, dayKeyCAT } from "./adPass";
import { metered } from "./featureBilling";
import { SCHOOL_TIMETABLE_ALLOWANCE, isWithinAllowance } from "./schoolAllowance";
import { resetBillingCaches } from "./markingBilling";
import { buildFinanceSummary, parseOwnerSettings } from "./revenue";
import { parseMarkingCreditsConfig } from "./credits";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error("Refusing to run: FIRESTORE_EMULATOR_HOST is not set. Use `npm run test:int` (it starts the emulator).");
}
admin.initializeApp({ projectId: "feature-billing-int-test" });
const db = admin.firestore();

let n = 0;
const newUid = () => `feat-user-${Date.now()}-${n++}`;
const ledger = async (uid: string) => (await db.collection("creditLedgers").doc(`user_${uid}`).get()).data();
const txns = async (uid: string) => (await db.collection("creditLedgers").doc(`user_${uid}`).collection("transactions").get()).docs.map((d) => d.data());

async function setConfig(over: Record<string, unknown>) {
  const cfg = { ...JSON.parse(JSON.stringify(DEFAULT_MARKING_CREDITS_CONFIG)), ...over };
  await db.collection("appConfig").doc("markingCredits").set(cfg);
  resetBillingCaches();
}

// A stand-in for Gemini that reports usage, so cost tracking is exercised too.
const fakeAi = {
  models: {
    generateContent: async () => ({
      text: "ok",
      candidates: [{ finishReason: "STOP" }],
      usageMetadata: { promptTokenCount: 2000, candidatesTokenCount: 1000, thoughtsTokenCount: 500 },
    }),
  },
} as unknown as GoogleGenAI;

let aiCalls = 0;
const okHandler = async () => {
  aiCalls++;
  await generateTracked(fakeAi, { model: "gemini-3.6-flash", contents: "x" });
  return { title: "A lesson plan" } as Record<string, unknown>;
};
const failingHandler = async () => {
  aiCalls++;
  await generateTracked(fakeAi, { model: "gemini-3.6-flash", contents: "x" });
  throw new Error("The AI did not return any content."); // the functions throw on an unusable result
};

const req = (uid: string | null, data: Record<string, unknown> = {}) =>
  ({ auth: uid ? { uid, token: {} } : undefined, data, rawRequest: {}, acceptsStreaming: false }) as unknown as CallableRequest<Record<string, unknown>>;

async function wipe(collection: string) {
  const snap = await db.collection(collection).get();
  await Promise.all(snap.docs.map((d) => d.ref.delete()));
}

beforeEach(async () => {
  aiCalls = 0;
  await Promise.all([wipe("adPasses"), wipe("adPassCounters"), wipe("featureUsage"), wipe("appConfig")]);
  await db.collection("ownerData").doc("usageAgg").delete();
  resetBillingCaches();
});

describe("metered — switched OFF (the shipped default)", () => {
  test("no config at all: the feature runs exactly as before — no charge, no ledger, no credits block", async () => {
    const uid = newUid();
    const r = await metered("lessonPlan", okHandler)(req(uid));
    expect(r).toEqual({ title: "A lesson plan" });
    expect(await ledger(uid)).toBeUndefined();
  });

  test("...but the real token cost is still recorded, so measured cost accrues from day one", async () => {
    const uid = newUid();
    await metered("lessonPlan", okHandler)(req(uid));
    const agg = (await db.collection("ownerData").doc("usageAgg").get()).data();
    expect(agg?.features?.lessonPlan).toMatchObject({ requests: 1, successes: 1, calls: 1 });
    expect(agg?.features?.lessonPlan.costUsd).toBeCloseTo((2000 * 0.75 + 1500 * 3.75) / 1e6, 8);
    const docs = await db.collection("featureUsage").get();
    expect(docs.size).toBe(1);
    expect(JSON.stringify(docs.docs[0].data())).not.toContain(uid);
  });

  test("a signed-out call goes straight to the handler untouched (which does its own sign-in refusal)", async () => {
    const r = await metered("lessonPlan", okHandler)(req(null));
    expect(r).toEqual({ title: "A lesson plan" });
  });

  test("marking mode 'enforced' alone does NOT start charging features", async () => {
    await setConfig({ mode: "enforced" });
    const uid = newUid();
    await metered("lessonPlan", okHandler)(req(uid));
    expect(await ledger(uid)).toBeUndefined();
  });
});

describe("metered — ENFORCED", () => {
  beforeEach(() => setConfig({ featuresMode: "enforced" }));

  test("a successful lesson plan costs 10 credits — exactly the 10 free credits a new teacher gets", async () => {
    const uid = newUid();
    const r = await metered("lessonPlan", okHandler)(req(uid, { requestId: "req-lesson-0001" }));
    expect(r.credits).toMatchObject({ mode: "enforced", feature: "lessonPlan", charged: 10, paidWith: "credits", balance: 0, duplicate: false });
    const l = await ledger(uid);
    expect(l?.freeUnits).toBe(0);
    expect(l?.purchasedUnits).toBe(0);
    const t = (await txns(uid)).find((x) => x.type === "spend");
    expect(t).toMatchObject({ kind: "feature", feature: "lessonPlan", units: -10_000 });
  });

  test("a FAILED generation is never charged — but its AI cost is still recorded as wasted spend", async () => {
    const uid = newUid();
    await expect(metered("lessonPlan", failingHandler)(req(uid))).rejects.toThrow("did not return");
    expect(await ledger(uid)).toBeUndefined();
    const agg = (await db.collection("ownerData").doc("usageAgg").get()).data();
    expect(agg?.features?.lessonPlan).toMatchObject({ requests: 1, successes: 0, calls: 1 });
    expect(agg?.features?.lessonPlan.costUsd).toBeGreaterThan(0);
  });

  test("a handler that returns an unusable result (isUsable=false) is not charged either", async () => {
    const uid = newUid();
    await metered("schemeOfWork", async () => ({ items: [] as unknown[] }), { isUsable: (r) => r.items.length > 0 })(req(uid));
    expect(await ledger(uid)).toBeUndefined();
  });

  test("not enough credits: refused BEFORE the AI call, with the exact numbers, and nothing is charged", async () => {
    const uid = newUid();
    await db.collection("creditLedgers").doc(`user_${uid}`).set({ ownerType: "user", ownerId: uid, purchasedUnits: 0, freeUnits: 4_000, freePeriod: "2099-01" });
    // freePeriod in the future is "not this month" -> the allowance would roll to 10 free. Use a matching period instead.
    const now = new Date(Date.now() + 2 * 3600_000);
    const period = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
    await db.collection("creditLedgers").doc(`user_${uid}`).set({ ownerType: "user", ownerId: uid, purchasedUnits: 0, freeUnits: 4_000, freePeriod: period });
    await expect(metered("lessonPlan", okHandler)(req(uid))).rejects.toMatchObject({
      code: "failed-precondition",
      details: { code: "insufficient_credits", feature: "lessonPlan", requiredCredits: 10, availableCredits: 4, adPassEligible: false },
    });
    expect(aiCalls).toBe(0);
    expect((await ledger(uid))?.freeUnits).toBe(4_000);
  });

  test("the SAME requestId is charged exactly once, however often it repeats", async () => {
    const uid = newUid();
    await db.collection("creditLedgers").doc(`user_${uid}`).set({ ownerType: "user", ownerId: uid, purchasedUnits: 100_000, freeUnits: 0, freePeriod: "2000-01" });
    const call = () => metered("transcription", okHandler)(req(uid, { requestId: "req-transcribe-1" }));
    const first = await call();
    const second = await call();
    expect(first.credits).toMatchObject({ charged: 4, duplicate: false });
    expect(second.credits).toMatchObject({ charged: 0, duplicate: true });
    // The new month's 10 free credits were granted and the 4 came out of THEM; bought credits untouched, and the repeat took nothing more.
    const l = await ledger(uid);
    expect(l?.freeUnits).toBe(6_000);
    expect(l?.purchasedUnits).toBe(100_000);
    expect((await txns(uid)).filter((t) => t.type === "spend")).toHaveLength(1);
  });

  test("different features with the same request id do not collide with each other", async () => {
    const uid = newUid();
    await db.collection("creditLedgers").doc(`user_${uid}`).set({ ownerType: "user", ownerId: uid, purchasedUnits: 100_000, freeUnits: 0, freePeriod: "2000-01" });
    const before = (await ledger(uid))?.purchasedUnits;
    await metered("transcription", okHandler)(req(uid, { requestId: "shared-request-id" }));
    await metered("teachingNotes", okHandler)(req(uid, { requestId: "shared-request-id" }));
    const l = await ledger(uid);
    // 10 free credits granted; 4 (transcription) + 8 (notes) = 12 spent: 10 free then 2 purchased. The second was NOT skipped as a "duplicate".
    expect(before).toBe(100_000);
    expect(l?.freeUnits).toBe(0);
    expect(l?.purchasedUnits).toBe(98_000);
    expect((await txns(uid)).filter((t) => t.type === "spend")).toHaveLength(2);
  });

  test("a 0-credit utility (voice command) is never charged or refused, even with an empty balance", async () => {
    const uid = newUid();
    await db.collection("creditLedgers").doc(`user_${uid}`).set({ ownerType: "user", ownerId: uid, purchasedUnits: 0, freeUnits: 0, freePeriod: "2000-01" });
    // freePeriod 2000-01 would roll to a fresh 10; the point is a 0-weight feature never even checks.
    const r = await metered("voiceCommand", okHandler)(req(uid));
    expect(r.credits).toBeUndefined();
    expect(aiCalls).toBe(1);
  });

  test("the price switch: after midnight 1 Jan 2027 (Zambia time) the same lesson plan costs 20", async () => {
    const realNow = Date.now;
    Date.now = () => Date.parse("2027-01-01T00:00:00+02:00");
    try {
      resetBillingCaches();
      const uid = newUid();
      await db.collection("creditLedgers").doc(`user_${uid}`).set({ ownerType: "user", ownerId: uid, purchasedUnits: 50_000, freeUnits: 0, freePeriod: "2027-01" });
      const r = await metered("lessonPlan", okHandler)(req(uid));
      expect(r.credits).toMatchObject({ charged: 20 });
      expect((await ledger(uid))?.purchasedUnits).toBe(30_000);
    } finally {
      Date.now = realNow;
    }
  });
});

describe("metered — SHADOW", () => {
  test("records what WOULD be charged, changes no balance and blocks nobody", async () => {
    await setConfig({ featuresMode: "shadow" });
    const uid = newUid();
    const r = await metered("lessonPlan", okHandler)(req(uid, { requestId: "req-shadow-001" }));
    expect(r.credits).toMatchObject({ mode: "shadow", charged: 0, cost: 10, balance: null });
    expect(await ledger(uid)).toBeUndefined();
    expect((await txns(uid)).map((t) => t.type)).toEqual(["shadow_spend"]);
  });
});

describe("ad passes", () => {
  const T = () => Date.now();
  const adsOn = () => setConfig({ featuresMode: "enforced", adPasses: { enabled: true, perDayCap: 5, ttlHours: 24 } });
  const noCredits = async (uid: string) => {
    const now = new Date(Date.now() + 2 * 3600_000);
    const period = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
    await db.collection("creditLedgers").doc(`user_${uid}`).set({ ownerType: "user", ownerId: uid, purchasedUnits: 0, freeUnits: 0, freePeriod: period });
  };
  const cfgOf = () => parseMarkingCreditsConfig({ featuresMode: "enforced", adPasses: { enabled: true, perDayCap: 5, ttlHours: 24 } });
  const earnPass = (uid: string, tx: string) => grantAdPass(db, { uid, transactionId: tx, cfg: cfgOf(), nowMs: T() });

  test("out of credits: the refusal offers an ad when ads are on", async () => {
    await adsOn();
    const uid = newUid();
    await noCredits(uid);
    await expect(metered("lessonPlan", okHandler)(req(uid))).rejects.toMatchObject({ details: { code: "insufficient_credits", adPassEligible: true } });
    expect(aiCalls).toBe(0);
  });

  test("an earned pass pays for ONE generation instead of credits — and is then spent", async () => {
    await adsOn();
    const uid = newUid();
    await noCredits(uid);
    expect((await earnPass(uid, "TX-1")).granted).toBe(true);

    const r = await metered("lessonPlan", okHandler)(req(uid, { requestId: "req-with-pass-1" }));
    expect(r.credits).toMatchObject({ charged: 0, paidWith: "ad" });
    expect((await ledger(uid))?.freeUnits).toBe(0); // credits untouched
    expect((await txns(uid)).map((t) => t.type)).toContain("ad_pass_spend");

    // the pass is gone: the next generation is refused again
    await expect(metered("lessonPlan", okHandler)(req(uid, { requestId: "req-with-pass-2" }))).rejects.toMatchObject({ details: { code: "insufficient_credits" } });
    expect(aiCalls).toBe(1);
  });

  test("a FAILED generation does not use up the pass", async () => {
    await adsOn();
    const uid = newUid();
    await noCredits(uid);
    await earnPass(uid, "TX-2");
    await expect(metered("lessonPlan", failingHandler)(req(uid))).rejects.toThrow();
    const r = await metered("lessonPlan", okHandler)(req(uid));
    expect(r.credits).toMatchObject({ paidWith: "ad" });
  });

  test("payWith 'ad' spends the pass even when the teacher has credits; without a pass it is refused before any AI call", async () => {
    await adsOn();
    const uid = newUid();
    await expect(metered("lessonPlan", okHandler)(req(uid, { payWith: "ad" }))).rejects.toMatchObject({ details: { code: "ad_pass_required" } });
    expect(aiCalls).toBe(0);

    await earnPass(uid, "TX-3");
    const r = await metered("lessonPlan", okHandler)(req(uid, { payWith: "ad" }));
    expect(r.credits).toMatchObject({ paidWith: "ad", charged: 0 });
    expect(await ledger(uid)).toBeUndefined(); // paid by ad: the credit balance was never even touched
  });

  test("one AdMob transaction earns ONE pass, however many times Google re-delivers the callback", async () => {
    await adsOn();
    const uid = newUid();
    const results = await Promise.all(Array.from({ length: 6 }, () => earnPass(uid, "TX-SAME")));
    expect(results.filter((r) => r.granted)).toHaveLength(1);
    expect((await db.collection("adPasses").where("uid", "==", uid).get()).size).toBe(1);
  });

  test("at most 5 passes a day per teacher (a bot farming ads can't mint unlimited free generations)", async () => {
    await adsOn();
    const uid = newUid();
    const outcomes = [];
    for (let i = 0; i < 8; i++) outcomes.push((await earnPass(uid, `TX-CAP-${i}`)).reason);
    expect(outcomes.filter((o) => o === "granted")).toHaveLength(5);
    expect(outcomes.filter((o) => o === "daily-cap")).toHaveLength(3);
    // a capped callback that Google retries is still recognised as already handled
    expect((await earnPass(uid, "TX-CAP-7")).reason).toBe("duplicate");
    const counter = await db.collection("adPassCounters").doc(hashId(`${uid}:${dayKeyCAT(T())}`)).get();
    expect(counter.data()?.count).toBe(5);
  });

  test("with ads switched OFF a verified callback mints nothing", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const r = await grantAdPass(db, { uid, transactionId: "TX-OFF", cfg: parseMarkingCreditsConfig({}), nowMs: T() });
    expect(r).toMatchObject({ granted: false, reason: "disabled" });
    expect((await db.collection("adPasses").where("uid", "==", uid).get()).size).toBe(0);
  });

  test("an EXPIRED pass, and another teacher's pass, pay for nothing", async () => {
    await adsOn();
    const uid = newUid();
    const other = newUid();
    await noCredits(uid);
    await db.collection("adPasses").doc("expired-pass").set({ uid, used: false, expiresAtMs: T() - 1000 });
    await db.collection("adPasses").doc("others-pass").set({ uid: other, used: false, expiresAtMs: T() + 3600_000 });
    await expect(metered("lessonPlan", okHandler)(req(uid))).rejects.toMatchObject({ details: { code: "insufficient_credits" } });
    expect((await db.collection("adPasses").doc("others-pass").get()).data()?.used).toBe(false);
  });

  test("ad passes are never accepted for MARKING (a marked script costs far more than an ad earns)", async () => {
    // Marking's charge path has no pass parameter at all; this pins that the feature charge is the only consumer.
    const { chargeSuccessfulMarking } = await import("./credits");
    expect(chargeSuccessfulMarking.length).toBe(2);
    const src = String(chargeSuccessfulMarking);
    expect(src).not.toContain("adPass");
  });
});

describe("owner finance summary: measured cost per feature use vs credits charged", () => {
  test("shows cost per successful use, the implied cost per credit, and flags nothing it has no data for", async () => {
    const cfg = parseMarkingCreditsConfig({});
    const s = buildFinanceSummary({
      settings: parseOwnerSettings({}),
      revenue: undefined,
      usageAgg: { features: { lessonPlan: { requests: 12, successes: 10, calls: 10, costUsd: 0.4 } } },
      cfg,
      nowMs: Date.parse("2026-10-01T00:00:00Z"),
    });
    expect(s.features.lessonPlan).toMatchObject({ successes: 10, creditsPerUse: 10 });
    expect(s.features.lessonPlan.measuredCostPerUseUsd).toBeCloseTo(0.04, 8);
    expect(s.features.lessonPlan.impliedCostPerCreditUsd).toBeCloseTo(0.004, 8); // above the $0.0026 target -> under-charging
    expect(s.features.teachingNotes.measuredCostPerUseUsd).toBeNull();
    expect(s.features.voiceCommand.impliedCostPerCreditUsd).toBeNull(); // 0-weight: not divisible
    expect(s.targetCostPerCreditUsd).toBe(0.0026);
    expect(s.config.featuresMode).toBe("off");
  });
});

// ---------------------------------------------------------------------------
// Subscribed schools: $1 of real AI cost a month INCLUDED for timetable work,
// then charged (owner's decision 2026-09-19).
// ---------------------------------------------------------------------------
describe("school timetable allowance ($1 of AI cost per school per month included)", () => {
  const ALLOWANCE = SCHOOL_TIMETABLE_ALLOWANCE;
  const school = () => `school-${Date.now()}-${n++}`;
  const period = () => {
    const now = new Date(Date.now() + 2 * 3600_000);
    return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
  };
  const usageDocId = (schoolId: string) => hashId(`${schoolId}:${period()}`);
  const seedUsage = (schoolId: string, usd: number) =>
    db.collection("schoolAiUsage").doc(usageDocId(schoolId)).set({ schoolId, groups: { timetable: { costUsd: usd } } });
  const usageOf = async (schoolId: string) => (await db.collection("schoolAiUsage").doc(usageDocId(schoolId)).get()).data()?.groups?.timetable?.costUsd as number | undefined;
  const timetableCall = (uid: string, schoolId: string, feature = "timetableAssist", handler = okHandler) =>
    metered(feature, handler, { schoolAllowance: ALLOWANCE })(req(uid, { schoolId }));
  const emptyWallet = async (uid: string) =>
    db.collection("creditLedgers").doc(`user_${uid}`).set({ ownerType: "user", ownerId: uid, purchasedUnits: 0, freeUnits: 0, freePeriod: period() });

  beforeEach(async () => {
    await wipe("schoolAiUsage");
  });

  test("under the allowance, timetable work is INCLUDED: nothing charged, no credits needed, even with an empty wallet", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const sid = school();
    await emptyWallet(uid);
    const r = await timetableCall(uid, sid);
    expect(r.credits).toMatchObject({ paidWith: "plan", charged: 0 });
    expect(aiCalls).toBe(1);
    expect((await ledger(uid))?.freeUnits).toBe(0);
    expect((await txns(uid)).filter((t) => t.type === "spend")).toHaveLength(0);
  });

  test("every use adds its REAL measured cost to the school's month, so the allowance really runs down", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const sid = school();
    await timetableCall(uid, sid);
    await timetableCall(uid, sid);
    expect(await usageOf(sid)).toBeCloseTo(2 * 0.007125, 8);
  });

  test("once the school has spent its $1, the next use is CHARGED in credits to the person making it", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const sid = school();
    await seedUsage(sid, 1.0);
    const r = await timetableCall(uid, sid);
    expect(r.credits).toMatchObject({ paidWith: "credits", charged: 3 }); // timetableAssist = 3 credits
    expect((await ledger(uid))?.freeUnits).toBe(7_000); // 10 free - 3
  });

  test("the use that crosses the line is still included; the one after it is charged ('charged if they spend MORE than $1')", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const sid = school();
    await seedUsage(sid, 0.999);
    expect((await timetableCall(uid, sid)).credits).toMatchObject({ paidWith: "plan", charged: 0 }); // 0.999 -> 1.006
    expect((await timetableCall(uid, sid)).credits).toMatchObject({ paidWith: "credits", charged: 3 });
  });

  test("over the allowance AND out of credits: refused BEFORE any AI call, like any other feature", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const sid = school();
    await seedUsage(sid, 5);
    await emptyWallet(uid);
    await expect(timetableCall(uid, sid)).rejects.toMatchObject({ details: { code: "insufficient_credits", feature: "timetableAssist" } });
    expect(aiCalls).toBe(0);
  });

  test("the school's deterministic timetable generation is included too, and charged (2 credits) only once the school is over", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const sid = school();
    const noAi = async () => ({ assignmentCount: 40 }) as Record<string, unknown>;
    expect((await timetableCall(uid, sid, "timetable", noAi)).credits).toMatchObject({ paidWith: "plan" });
    await seedUsage(sid, 1.2);
    expect((await timetableCall(uid, sid, "timetable", noAi)).credits).toMatchObject({ paidWith: "credits", charged: 2 });
  });

  test("the allowance is PER SCHOOL: one school being over never charges another", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const busy = school();
    const quiet = school();
    await seedUsage(busy, 3);
    expect((await timetableCall(uid, quiet)).credits).toMatchObject({ paidWith: "plan" });
  });

  test("it resets each MONTH: last month's spend does not count", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const sid = school();
    await db.collection("schoolAiUsage").doc(hashId(`${sid}:2020-01`)).set({ schoolId: sid, groups: { timetable: { costUsd: 50 } } });
    expect((await timetableCall(uid, sid)).credits).toMatchObject({ paidWith: "plan" });
  });

  test("the size of the allowance is config: at $0.50 a school with $0.60 spent is already charged", async () => {
    await setConfig({ featuresMode: "enforced", schoolAllowancesUsd: { timetable: 0.5 } });
    const uid = newUid();
    const sid = school();
    await seedUsage(sid, 0.6);
    expect((await timetableCall(uid, sid)).credits).toMatchObject({ paidWith: "credits" });
  });

  test("a $0 allowance means no inclusion at all", async () => {
    await setConfig({ featuresMode: "enforced", schoolAllowancesUsd: { timetable: 0 } });
    const uid = newUid();
    expect((await timetableCall(uid, school())).credits).toMatchObject({ paidWith: "credits" });
  });

  test("a request with no school id is an ordinary metered use (no allowance applies)", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const r = await metered("timetableAssist", okHandler, { schoolAllowance: ALLOWANCE })(req(uid, {}));
    expect(r.credits).toMatchObject({ paidWith: "credits", charged: 3 });
  });

  test("while features are switched OFF nothing is charged, but the school's spend is still counted from day one", async () => {
    const uid = newUid();
    const sid = school();
    const r = await timetableCall(uid, sid);
    expect(r.credits).toBeUndefined();
    expect(await ledger(uid)).toBeUndefined();
    expect(await usageOf(sid)).toBeCloseTo(0.007125, 8);
  });

  test("SHADOW mode: an included use writes no would-be charge; one over the allowance does", async () => {
    await setConfig({ featuresMode: "shadow" });
    const uid = newUid();
    const sid = school();
    await timetableCall(uid, sid);
    expect(await txns(uid)).toHaveLength(0);
    await seedUsage(sid, 2);
    await timetableCall(uid, sid);
    expect((await txns(uid)).map((t) => t.type)).toEqual(["shadow_spend"]);
  });

  test("a FAILED call still counts its real API spend against the school, but is never charged", async () => {
    await setConfig({ featuresMode: "enforced" });
    const uid = newUid();
    const sid = school();
    await expect(timetableCall(uid, sid, "timetableAssist", failingHandler)).rejects.toThrow();
    expect(await usageOf(sid)).toBeCloseTo(0.007125, 8);
    expect(await ledger(uid)).toBeUndefined();
  });

  test("isWithinAllowance: the arithmetic of the line", () => {
    expect(isWithinAllowance(0, 1)).toBe(true);
    expect(isWithinAllowance(0.9999, 1)).toBe(true);
    expect(isWithinAllowance(1, 1)).toBe(false);
    expect(isWithinAllowance(0, 0)).toBe(false);
  });
});
