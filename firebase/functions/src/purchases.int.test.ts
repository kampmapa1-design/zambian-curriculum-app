// Emulator tests for the whole purchase pipeline (Stage 4a-4f), against a FAKE
// Google Play (it records every call made to it) and a FAKE owner notifier - so
// nothing here touches Google or sends email. Organised by the stage of the
// brief each group of tests proves.
import * as admin from "firebase-admin";
import { DEFAULT_MARKING_CREDITS_CONFIG, hashId } from "./credits";
import { resetBillingCaches } from "./markingBilling";
import { findBundle, obfuscatedAccountId, type RedeemDeps } from "./monetization";
import {
  PLAY_PACKAGE_NAME,
  PlayVerificationError,
  type PlayOrder,
  type PlayPurchase,
  type PlayVerifier,
  type VoidedPurchase,
} from "./playBilling";
import { PURCHASE_RATE } from "./purchaseAudit";
import { handlePlayNotification, reconcileVoidedPurchases } from "./purchaseRefunds";
import { redeemBundle, retryPendingAcknowledgements, verifyBundlePurchase } from "./purchaseVerification";
import { DAY_MS } from "./revenue";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error("Refusing to run: FIRESTORE_EMULATOR_HOST is not set. Use `npm run test:int` (it starts the emulator).");
}
admin.initializeApp({ projectId: "purchases-int-test" });
const db = admin.firestore();
const NOW = Date.parse("2026-09-19T10:00:00Z");
const HOUR = 60 * 60 * 1000;

let n = 0;
const newUid = () => `buyer-${Date.now()}-${n++}`;
const tokenFor = (uid: string, tag = "a") => `purchase-token-${uid}-${tag}-SECRET0123456789`;
const LIST: Record<string, number> = { marking_bundle_k50: 50, marking_bundle_k100: 100, marking_bundle_k150: 150 };

/** A fake Google Play that records what it was asked and can be told to misbehave. */
class FakePlay implements PlayVerifier {
  calls = { verify: 0, acknowledge: 0, getOrder: 0, listVoided: 0 };
  acknowledged = new Set<string>();
  verifyError: unknown = null;
  ackError: unknown = null;
  orderError: unknown = null;
  /** When acknowledge() fails with "invalid", also mark it acknowledged (Google saying "already done"). */
  markAckedOnInvalid = false;
  purchase: Partial<PlayPurchase> = {};
  order: Partial<PlayOrder> = {};
  voided: VoidedPurchase[] = [];
  voidedTruncated = false;
  private lastProduct = "marking_bundle_k50";
  constructor(private readonly boundUid: string) {}

  async verify(productId: string, token: string): Promise<PlayPurchase> {
    this.calls.verify++;
    if (this.verifyError) throw this.verifyError;
    this.lastProduct = productId;
    return {
      purchaseState: 0, consumptionState: 0, acknowledgementState: this.acknowledged.has(token) ? 1 : 0, orderId: "GPA.0000-1111",
      purchaseTimeMillis: NOW, regionCode: "ZM", quantity: 1, obfuscatedExternalAccountId: obfuscatedAccountId(this.boundUid),
      productId, purchaseType: null, ...this.purchase,
    };
  }
  async acknowledge(_productId: string, token: string): Promise<void> {
    this.calls.acknowledge++;
    if (this.ackError) {
      if (this.markAckedOnInvalid) this.acknowledged.add(token);
      throw this.ackError;
    }
    this.acknowledged.add(token);
  }
  async getOrder(): Promise<PlayOrder> {
    this.calls.getOrder++;
    if (this.orderError) throw this.orderError;
    const price = LIST[this.lastProduct] ?? 50;
    return {
      state: "PROCESSED", total: { currency: "ZMW", amount: price }, tax: null, developerRevenue: { currency: "ZMW", amount: price * 0.75 },
      lineItemProductIds: [this.lastProduct], buyerCountry: "ZM", ...this.order,
    };
  }
  async listVoidedPurchases() {
    this.calls.listVoided++;
    return { purchases: this.voided, truncated: this.voidedTruncated };
  }
}

let notifications: { subject: string; html: string }[] = [];
const mk = (fake: FakePlay, nowMs = NOW): RedeemDeps => ({
  db, verifier: fake, nowMs, notifyOwner: async (subject, html) => { notifications.push({ subject, html }); },
});
const buy = (fake: FakePlay, uid: string, o: { productId?: string; token?: string; nowMs?: number; anonymous?: boolean } = {}) =>
  verifyBundlePurchase(mk(fake, o.nowMs ?? NOW), {
    uid, isAnonymous: o.anonymous ?? false, productId: o.productId ?? "marking_bundle_k50", purchaseToken: o.token ?? tokenFor(uid),
  });

const ledger = async (uid: string) => (await db.collection("creditLedgers").doc(`user_${uid}`).get()).data();
const processed = async (token: string) => (await db.collection("processedPurchases").doc(hashId(token)).get()).data();
const revenue = async () => (await db.collection("ownerData").doc("revenue").get()).data();
const auditDocs = async () => (await db.collection("purchaseAuditLog").get()).docs.map((d) => d.data());
const auditSteps = async (key?: string) => (await auditDocs()).filter((d) => !key || d.purchaseKey === key).map((d) => d.step as string);
const anomalyTypes = async () => (await db.collection("purchaseAnomalies").get()).docs.map((d) => d.data().type as string);
const setCfg = async (over: Record<string, unknown>) => {
  await db.collection("appConfig").doc("markingCredits").set({ ...JSON.parse(JSON.stringify(DEFAULT_MARKING_CREDITS_CONFIG)), ...over });
  resetBillingCaches();
};
async function wipe(collection: string) {
  const snap = await db.collection(collection).get();
  await Promise.all(snap.docs.map((d) => d.ref.delete()));
}

beforeEach(async () => {
  notifications = [];
  resetBillingCaches();
  await Promise.all(["revenueEvents", "processedPurchases", "appConfig", "purchaseAuditLog", "purchaseAnomalies", "purchaseRate"].map(wipe));
  await db.collection("ownerData").doc("revenue").delete();
  await db.collection("ownerData").doc("settings").delete();
});

// ======================================================================== 4a
describe("4a — server-side verification: never trust the client", () => {
  test("a verified K50 purchase credits 87 credits, counts K50 of revenue, and Google was actually asked", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    const r = await buy(fake, uid);
    expect(r).toMatchObject({ creditsGranted: 87, duplicate: false, balance: 87, acknowledged: true });
    expect((await ledger(uid))?.purchasedUnits).toBe(87_000);
    expect(fake.calls.verify).toBe(1);
    expect(fake.calls.getOrder).toBe(1);
    expect(await revenue()).toMatchObject({ rolling12mKwacha: 50, eventCount: 1 });
  });

  test("the old function name still works (app builds already in testers' hands call it)", async () => {
    const uid = newUid();
    const r = await redeemBundle(mk(new FakePlay(uid)), { uid, isAnonymous: false, productId: "marking_bundle_k100", purchaseToken: tokenFor(uid) });
    expect(r.creditsGranted).toBe(178);
  });

  test("pending and cancelled purchases are NOT credited and NOT acknowledged", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.purchase = { purchaseState: 2 };
    await expect(buy(fake, uid)).rejects.toMatchObject({ code: "failed-precondition", details: { code: "purchase_pending" } });
    fake.purchase = { purchaseState: 1 };
    await expect(buy(fake, uid)).rejects.toMatchObject({ code: "failed-precondition" });
    expect(await ledger(uid)).toBeUndefined();
    expect(fake.calls.acknowledge).toBe(0);
  });

  test("Google says the token is for a DIFFERENT product than the client claimed: refused and flagged", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.purchase = { productId: "marking_bundle_k50" };
    await expect(buy(fake, uid, { productId: "marking_bundle_k150" })).rejects.toMatchObject({ code: "invalid-argument" });
    expect(await ledger(uid)).toBeUndefined();
    expect(await anomalyTypes()).toContain("product_mismatch");
  });

  test("the ORDER's line items must include the product too", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.order = { lineItemProductIds: ["some_other_product"] };
    await expect(buy(fake, uid)).rejects.toMatchObject({ code: "invalid-argument" });
    expect(await ledger(uid)).toBeUndefined();
    expect(await anomalyTypes()).toContain("order_product_mismatch");
  });

  test("an order Google reports as REFUNDED/CANCELED is never credited", async () => {
    for (const state of ["REFUNDED", "CANCELED", "PENDING_REFUND"]) {
      const uid = newUid();
      const fake = new FakePlay(uid);
      fake.order = { state };
      await expect(buy(fake, uid)).rejects.toMatchObject({ code: "failed-precondition" });
      expect(await ledger(uid)).toBeUndefined();
      expect(fake.calls.acknowledge).toBe(0);
    }
  });

  test("a token bought by ANOTHER account (or with no account binding) is refused and flagged", async () => {
    const thief = newUid();
    const victim = newUid();
    await expect(buy(new FakePlay(victim), thief, { token: tokenFor(victim) })).rejects.toMatchObject({ code: "permission-denied" });
    const unbound = new FakePlay(thief);
    unbound.purchase = { obfuscatedExternalAccountId: null };
    await expect(buy(unbound, thief, { token: tokenFor(thief, "b") })).rejects.toMatchObject({ code: "permission-denied" });
    expect(await ledger(thief)).toBeUndefined();
    expect(await anomalyTypes()).toEqual(["account_binding_mismatch", "account_binding_mismatch"]);
  });

  test("Play access not set up FAILS CLOSED: no credits, no acknowledgement, a clear 'try later' error", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.verifyError = new PlayVerificationError("unauthorized", "no access");
    await expect(buy(fake, uid)).rejects.toMatchObject({ code: "failed-precondition", details: { code: "verification_unavailable" } });
    fake.verifyError = new PlayVerificationError("invalid", "no such token");
    await expect(buy(fake, uid)).rejects.toMatchObject({ code: "invalid-argument" });
    fake.verifyError = new PlayVerificationError("unavailable", "timeout");
    await expect(buy(fake, uid)).rejects.toMatchObject({ code: "unavailable" });
    expect(await ledger(uid)).toBeUndefined();
    expect(fake.calls.acknowledge).toBe(0);
  });

  test("garbage input and unknown products are refused WITHOUT asking Google", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    await expect(verifyBundlePurchase(mk(fake), { uid, isAnonymous: false, productId: 42, purchaseToken: "x" })).rejects.toMatchObject({ code: "invalid-argument" });
    await expect(buy(fake, uid, { productId: "premium_gold_forever" })).rejects.toMatchObject({ code: "invalid-argument" });
    expect(fake.calls.verify).toBe(0);
  });

  test("an anonymous account is refused - its credits would vanish on reinstall", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    await expect(buy(fake, uid, { anonymous: true })).rejects.toMatchObject({ code: "failed-precondition", details: { code: "sign_in_required" } });
    expect(fake.calls.verify).toBe(0);
    expect(await ledger(uid)).toBeUndefined();
  });

  test("a purchase made under an earlier price scenario is still honoured after the active scenario changes", async () => {
    const cfg = JSON.parse(JSON.stringify(DEFAULT_MARKING_CREDITS_CONFIG));
    cfg.bundles.activeScenario = "scenario2";
    cfg.bundles.scenarios.scenario2 = { marking_bundle_k100: { credits: 150, listPrice: { amount: 100, currency: "ZMW" } } };
    await db.collection("appConfig").doc("markingCredits").set(cfg);
    const uid = newUid();
    const r1 = await buy(new FakePlay(uid), uid, { productId: "marking_bundle_k100", token: tokenFor(uid, "1") });
    const r2 = await buy(new FakePlay(uid), uid, { productId: "marking_bundle_k50", token: tokenFor(uid, "2") });
    expect(r1.creditsGranted).toBe(150);
    expect(r2.creditsGranted).toBe(87);
    expect(findBundle(cfg, "nope")).toBeNull();
  });

  test("the VAT alert fires ONCE, on the purchase that crosses the threshold", async () => {
    await db.collection("ownerData").doc("settings").set({ vatThresholdKwacha: 150, ownerEmail: "owner@example.com" });
    const [a, b, c] = [newUid(), newUid(), newUid()];
    await buy(new FakePlay(a), a, { productId: "marking_bundle_k100" });
    expect(notifications).toHaveLength(0);
    await buy(new FakePlay(b), b, { productId: "marking_bundle_k100" });
    expect(notifications.map((x) => x.subject)).toEqual([expect.stringMatching(/VAT threshold/)]);
    await buy(new FakePlay(c), c);
    expect(notifications).toHaveLength(1);
    expect(await revenue()).toMatchObject({ vatThresholdCrossed: true, rolling12mKwacha: 250 });
  });
});

// ================================================================= 4a / 4e price
describe("4a/4e — the price actually paid (Google's purchase lookup has no price; the Orders API does)", () => {
  const paid = (amount: number, currency = "ZMW"): Partial<PlayOrder> => ({ total: { currency, amount } });

  test("paid the bundle price: credited, no anomaly, price recorded as a match", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    await buy(new FakePlay(uid), uid, { token: t });
    expect(await anomalyTypes()).toEqual([]);
    expect((await processed(t))?.priceStatus).toBe("match");
  });

  test("UNDER-paid (K30 for a K50 bundle): NOT credited and NOT acknowledged (Google will refund), flagged, owner emailed", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.order = paid(30);
    await expect(buy(fake, uid)).rejects.toMatchObject({ code: "failed-precondition", details: { code: "purchase_held" } });
    expect(await ledger(uid)).toBeUndefined();
    expect(fake.calls.acknowledge).toBe(0);
    expect(await anomalyTypes()).toContain("price_underpaid");
    expect(notifications[0].subject).toMatch(/BELOW the bundle price/);
    expect(notifications[0].html).toMatch(/not credited and not acknowledged/);
    expect((await revenue())?.rolling12mKwacha ?? 0).toBe(0);
  });

  test("with the price check set to 'flag', an under-payment IS credited but still flagged and emailed", async () => {
    await setCfg({ purchasePolicy: { priceCheck: "flag", tolerancePercent: 2 } });
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.order = paid(30);
    await expect(buy(fake, uid)).resolves.toMatchObject({ creditsGranted: 87 });
    expect(await anomalyTypes()).toContain("price_underpaid");
    expect(notifications).toHaveLength(1);
  });

  test("within the tolerance (K49.60 for K50) is a match; a clear over-payment is credited and flagged", async () => {
    const a = newUid();
    const fa = new FakePlay(a);
    fa.order = paid(49.6);
    await buy(fa, a);
    expect(await anomalyTypes()).toEqual([]);

    const b = newUid();
    const fb = new FakePlay(b);
    fb.order = paid(60);
    await expect(buy(fb, b)).resolves.toMatchObject({ creditsGranted: 87 });
    expect(await anomalyTypes()).toEqual(["price_overpaid"]);
  });

  test("a buyer in another currency can't be compared: credited, not flagged, and the observed amount is kept", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    fake.order = paid(2.5, "USD");
    await buy(fake, uid, { token: t });
    expect(await anomalyTypes()).toEqual([]);
    expect(await processed(t)).toMatchObject({ priceStatus: "currency_differs", priceObserved: { currency: "USD", amount: 2.5 } });
  });

  test("if the order can't be read the purchase is still credited (product + state were verified), flagged, and revenue falls back to the list price", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.orderError = new PlayVerificationError("unavailable", "orders api down");
    await expect(buy(fake, uid)).resolves.toMatchObject({ creditsGranted: 87 });
    expect(await anomalyTypes()).toContain("price_unverified");
    expect((await revenue())?.rolling12mKwacha).toBe(50);
  });

  test("revenue is what was ACTUALLY paid, not the list price, when Google reports it (K55 paid -> K55)", async () => {
    await setCfg({ purchasePolicy: { priceCheck: "flag", tolerancePercent: 2 } });
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.order = paid(55);
    await buy(fake, uid);
    expect((await revenue())?.rolling12mKwacha).toBe(55);
    const ev = (await db.collection("revenueEvents").get()).docs[0].data();
    expect(ev.basis).toBe("play_order_total");
    expect(ev.developerRevenue).toMatchObject({ currency: "ZMW" }); // Google's net-of-fees figure, kept for the accountant
  });

  test("a USD-priced bundle is converted to kwacha at the STORED exchange rate", async () => {
    const cfg = JSON.parse(JSON.stringify(DEFAULT_MARKING_CREDITS_CONFIG));
    cfg.bundles.scenarios.scenario1 = { usd_bundle: { credits: 100, listPrice: { amount: 2.5, currency: "USD" } } };
    await db.collection("appConfig").doc("markingCredits").set(cfg);
    await db.collection("ownerData").doc("settings").set({ fxUsdToZmw: { rate: 24, updatedAtMs: NOW } });
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.order = paid(2.5, "USD");
    await buy(fake, uid, { productId: "usd_bundle" });
    expect((await revenue())?.rolling12mKwacha).toBe(60);
  });

  test("test (licence-tester), promo and rewarded purchases are credited but are NOT revenue and skip the price check", async () => {
    for (const purchaseType of [0, 1, 2]) {
      const uid = newUid();
      const t = tokenFor(uid);
      const fake = new FakePlay(uid);
      fake.purchase = { purchaseType };
      fake.order = paid(0);
      await expect(buy(fake, uid, { token: t })).resolves.toMatchObject({ creditsGranted: 87 });
      expect((await processed(t))?.priceStatus).toBe("skipped_nonpaid");
    }
    expect(await anomalyTypes()).toEqual([]);
    expect((await revenue())?.rolling12mKwacha ?? 0).toBe(0);
  });

  test("price check switched OFF: an under-payment is not compared at all", async () => {
    await setCfg({ purchasePolicy: { priceCheck: "off", tolerancePercent: 2 } });
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.order = paid(1);
    await expect(buy(fake, uid)).resolves.toMatchObject({ creditsGranted: 87 });
    expect(await anomalyTypes()).toEqual([]);
  });
});

// ======================================================================== 4b
describe("4b — idempotency: one real payment can never credit twice", () => {
  test("REPLAY of the same token, sequentially: credited once; the repeat is 'duplicate' and Google is NOT asked again", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    const first = await buy(fake, uid);
    const askedAfterFirst = fake.calls.verify;
    const second = await buy(fake, uid);
    const third = await buy(fake, uid);
    expect(first).toMatchObject({ creditsGranted: 87, duplicate: false });
    expect(second).toMatchObject({ creditsGranted: 0, duplicate: true });
    expect(third).toMatchObject({ creditsGranted: 0, duplicate: true });
    expect(fake.calls.verify).toBe(askedAfterFirst); // checked BEFORE calling Google
    expect((await ledger(uid))?.purchasedUnits).toBe(87_000);
    expect((await revenue())?.rolling12mKwacha).toBe(50);
    expect(second.balance).toBe(87);
  });

  test("REPLAY in parallel (6 simultaneous deliveries of one purchase): exactly one credit, one revenue event, one ledger entry", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    const results = await Promise.all(Array.from({ length: 6 }, () => buy(fake, uid, { token: t })));
    expect(results.filter((r) => !r.duplicate)).toHaveLength(1);
    expect(results.reduce((s, r) => s + r.creditsGranted, 0)).toBe(87);
    expect((await ledger(uid))?.purchasedUnits).toBe(87_000);
    expect((await db.collection("revenueEvents").get()).size).toBe(1);
    const tx = (await db.collection("creditLedgers").doc(`user_${uid}`).collection("transactions").get()).docs.filter((d) => d.data().type === "purchase");
    expect(tx).toHaveLength(1);
  });

  test("two DIFFERENT purchases both credit", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: tokenFor(uid, "1") });
    await buy(fake, uid, { productId: "marking_bundle_k100", token: tokenFor(uid, "2") });
    expect((await ledger(uid))?.purchasedUnits).toBe(265_000);
  });

  test("REPLAY by a DIFFERENT account (someone else's token): denied, flagged, nothing credited to anyone new", async () => {
    const victim = newUid();
    const thief = newUid();
    const t = tokenFor(victim);
    await buy(new FakePlay(victim), victim, { token: t });
    const fake = new FakePlay(thief);
    await expect(buy(fake, thief, { token: t })).rejects.toMatchObject({ code: "permission-denied" });
    expect(await ledger(thief)).toBeUndefined();
    expect((await ledger(victim))?.purchasedUnits).toBe(87_000);
    expect(await anomalyTypes()).toContain("token_replay_other_account");
    expect(fake.calls.verify).toBe(0);
  });

  test("the processed record is keyed by a HASH of the token (never the raw token), and the raw token is not left lying around once acknowledged", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    await buy(new FakePlay(uid), uid, { token: t });
    const ids = (await db.collection("processedPurchases").get()).docs.map((d) => d.id);
    expect(ids).toEqual([hashId(t)]);
    expect(ids[0]).not.toContain("SECRET");
    expect((await processed(t))?.purchaseToken).toBeUndefined();
  });

  test("a REFUNDED purchase's token can't be redeemed again", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    await handlePlayNotification(mk(fake), { packageName: PLAY_PACKAGE_NAME, voidedPurchaseNotification: { purchaseToken: t, productType: 2, refundType: 1 } });
    await expect(buy(fake, uid, { token: t })).rejects.toMatchObject({ code: "failed-precondition" });
    expect((await ledger(uid))?.purchasedUnits).toBe(0);
  });
});

// ======================================================================== 4c
describe("4c — acknowledge every credited purchase (or Google refunds it in 3 days)", () => {
  test("a credited purchase is acknowledged exactly once, and that is recorded", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    const r = await buy(fake, uid, { token: t });
    expect(r.acknowledged).toBe(true);
    expect(fake.calls.acknowledge).toBe(1);
    expect(fake.acknowledged.has(t)).toBe(true);
    expect(await processed(t)).toMatchObject({ ackStatus: "acknowledged", status: "credited" });
    expect(await auditSteps(hashId(t))).toContain("ack_sent");
  });

  test("a purchase Google already shows as acknowledged is not acknowledged again", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.purchase = { acknowledgementState: 1 };
    const r = await buy(fake, uid);
    expect(r.acknowledged).toBe(true);
    expect(fake.calls.acknowledge).toBe(0);
  });

  test("NOTHING that is refused is ever acknowledged (pending, wrong account, held for price, blocked account)", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.purchase = { purchaseState: 2 };
    await buy(fake, uid).catch(() => undefined);
    fake.purchase = { obfuscatedExternalAccountId: obfuscatedAccountId("someone-else") };
    await buy(fake, uid, { token: tokenFor(uid, "x") }).catch(() => undefined);
    fake.purchase = {};
    fake.order = { total: { currency: "ZMW", amount: 5 } };
    await buy(fake, uid, { token: tokenFor(uid, "y") }).catch(() => undefined);
    expect(fake.calls.acknowledge).toBe(0);
  });

  test("if acknowledging FAILS the customer is still credited, and the failure is recorded for a retry", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    fake.ackError = new PlayVerificationError("unavailable", "google is down");
    const r = await buy(fake, uid, { token: t });
    expect(r).toMatchObject({ creditsGranted: 87, acknowledged: false });
    expect(await processed(t)).toMatchObject({ ackStatus: "failed", ackAttempts: 1, purchaseToken: t });
    expect(await auditSteps(hashId(t))).toContain("ack_failed");
  });

  test("the hourly retry acknowledges it once Google recovers, and then drops the stored token", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    fake.ackError = new PlayVerificationError("unavailable", "google is down");
    await buy(fake, uid, { token: t });
    fake.ackError = null;
    const r = await retryPendingAcknowledgements(mk(fake, NOW + HOUR));
    expect(r).toMatchObject({ attempted: 1, acknowledged: 1 });
    expect(fake.acknowledged.has(t)).toBe(true);
    const p = await processed(t);
    expect(p?.ackStatus).toBe("acknowledged");
    expect(p?.purchaseToken).toBeUndefined();
  });

  test("the retry leaves a brand-new purchase alone (a request may still be acknowledging it), and does nothing when nothing is pending", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.ackError = new PlayVerificationError("unavailable", "down");
    await buy(fake, uid);
    fake.ackError = null;
    expect(await retryPendingAcknowledgements(mk(fake, NOW + 60_000))).toMatchObject({ attempted: 0 });
    expect(await retryPendingAcknowledgements(mk(fake, NOW + HOUR))).toMatchObject({ attempted: 1, acknowledged: 1 });
    expect(await retryPendingAcknowledgements(mk(fake, NOW + 2 * HOUR))).toMatchObject({ attempted: 0 });
  });

  test("Google answering 'invalid' because it was ALREADY acknowledged is treated as success, not failure", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    fake.ackError = new PlayVerificationError("invalid", "already acknowledged");
    fake.markAckedOnInvalid = true;
    const r = await buy(fake, uid, { token: t });
    expect(r.acknowledged).toBe(true);
    expect((await processed(t))?.ackStatus).toBe("acknowledged");
  });

  test("a duplicate delivery re-tries an acknowledgement that failed the first time", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    fake.ackError = new PlayVerificationError("unavailable", "down");
    await buy(fake, uid, { token: t });
    fake.ackError = null;
    const again = await buy(fake, uid, { token: t });
    expect(again).toMatchObject({ duplicate: true, creditsGranted: 0, acknowledged: true });
    expect(fake.acknowledged.has(t)).toBe(true);
  });

  test("still failing after 24h: the owner is told ONCE; after 3 days it is recorded as lost", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    fake.ackError = new PlayVerificationError("unauthorized", "no access");
    await buy(fake, uid, { token: t });
    await retryPendingAcknowledgements(mk(fake, NOW + 25 * HOUR));
    await retryPendingAcknowledgements(mk(fake, NOW + 26 * HOUR));
    expect(notifications.filter((x) => /isn't acknowledged/.test(x.subject))).toHaveLength(1);
    expect(await anomalyTypes()).toContain("acknowledgement_failing");
    const r = await retryPendingAcknowledgements(mk(fake, NOW + 4 * DAY_MS));
    expect(r.expired).toBe(1);
    expect((await processed(t))?.ackStatus).toBe("expired");
  });
});

// ======================================================================== 4d
describe("4d — refunds and voided purchases (Real-time Developer Notifications)", () => {
  const voidMsg = (token: string, extra: Record<string, unknown> = {}) => ({
    version: "1.0", packageName: PLAY_PACKAGE_NAME, eventTimeMillis: String(NOW),
    voidedPurchaseNotification: { purchaseToken: token, orderId: "GPA.0000-1111", productType: 2, refundType: 1, ...extra },
  });
  const spendDownTo = (uid: string, units: number) => db.collection("creditLedgers").doc(`user_${uid}`).update({ purchasedUnits: units });

  test("a refund of UNSPENT credits takes them all back, marks the purchase voided, reverses the revenue and audits it", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    expect((await revenue())?.rolling12mKwacha).toBe(50);

    const r = await handlePlayNotification(mk(fake), voidMsg(t));
    expect(r.handled).toBe("voided:reversed");
    const l = await ledger(uid);
    expect(l?.purchasedUnits).toBe(0);
    expect(l?.debtUnits).toBe(0);
    expect(await processed(t)).toMatchObject({ status: "voided", reversal: { deductedUnits: 87_000, debtAddedUnits: 0 } });
    expect((await processed(t))?.purchaseToken).toBeUndefined();
    expect((await revenue())?.rolling12mKwacha).toBe(0);
    expect(await auditSteps(hashId(t))).toEqual(expect.arrayContaining(["void_received", "voided_reversal"]));
    expect(notifications).toHaveLength(0); // an ordinary refund needs no attention
  });

  test("a refund AFTER some credits were spent: unspent part taken back, the spent part recorded as DEBT (never a negative balance), owner told", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    await spendDownTo(uid, 37_000); // spent 50 of the 87

    const r = await handlePlayNotification(mk(fake), voidMsg(t));
    expect(r.handled).toBe("voided:reversed");
    const l = await ledger(uid);
    expect(l?.purchasedUnits).toBe(0);
    expect(l?.debtUnits).toBe(50_000);
    expect(l!.purchasedUnits).toBeGreaterThanOrEqual(0);
    expect(await anomalyTypes()).toContain("refund_spent_credits");
    expect(notifications[0].subject).toMatch(/already spent/);
    expect(notifications[0].html).toContain("50");
  });

  test("the debt is repaid FIRST out of the customer's next purchase", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    await spendDownTo(uid, 37_000);
    await handlePlayNotification(mk(fake), voidMsg(t)); // debt 50

    const next = await buy(fake, uid, { token: tokenFor(uid, "2") }); // K50 bundle = 87 credits
    expect(next.creditsGranted).toBe(37); // 87 - 50 repaid
    expect(next.debtRepaidCredits).toBe(50);
    const l = await ledger(uid);
    expect(l?.debtUnits).toBe(0);
    expect(l?.purchasedUnits).toBe(37_000);
  });

  test("a refund never touches the FREE monthly credits", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    await db.collection("creditLedgers").doc(`user_${uid}`).update({ freeUnits: 6_000, freePeriod: "2026-09" });
    await handlePlayNotification(mk(fake), voidMsg(t));
    expect((await ledger(uid))?.freeUnits).toBe(6_000);
  });

  test("a SECOND refund inside the window pauses the account's purchases: nothing is verified, charged-through or acknowledged, and the owner is told", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    const [t1, t2, t3] = [tokenFor(uid, "1"), tokenFor(uid, "2"), tokenFor(uid, "3")];
    await buy(fake, uid, { token: t1 });
    await buy(fake, uid, { token: t2 });
    await handlePlayNotification(mk(fake), voidMsg(t1));
    expect((await ledger(uid))?.purchasesBlocked).not.toBe(true);
    await handlePlayNotification(mk(fake), voidMsg(t2));
    expect((await ledger(uid))?.purchasesBlocked).toBe(true);
    expect(await anomalyTypes()).toContain("account_blocked");
    expect(notifications.some((x) => /paused after repeated refunds/.test(x.subject))).toBe(true);

    const askedBefore = fake.calls.verify;
    const ackBefore = fake.calls.acknowledge;
    await expect(buy(fake, uid, { token: t3 })).rejects.toMatchObject({ code: "failed-precondition", details: { code: "purchases_blocked" } });
    expect(fake.calls.verify).toBe(askedBefore);
    expect(fake.calls.acknowledge).toBe(ackBefore); // not acknowledged -> Google refunds it
    expect(await anomalyTypes()).toContain("blocked_account_purchase_attempt");
  });

  test("the owner can clear the pause (purchasesBlocked = false) and the account can buy again", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    const [t1, t2] = [tokenFor(uid, "1"), tokenFor(uid, "2")];
    await buy(fake, uid, { token: t1 });
    await buy(fake, uid, { token: t2 });
    await handlePlayNotification(mk(fake), voidMsg(t1));
    await handlePlayNotification(mk(fake), voidMsg(t2));
    await db.collection("creditLedgers").doc(`user_${uid}`).update({ purchasesBlocked: false });
    await expect(buy(fake, uid, { token: tokenFor(uid, "3") })).resolves.toMatchObject({ creditsGranted: 87 });
  });

  test("refunds OUTSIDE the 90-day window don't add up to a block", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    const [t1, t2] = [tokenFor(uid, "1"), tokenFor(uid, "2")];
    await buy(fake, uid, { token: t1 });
    await buy(fake, uid, { token: t2 });
    await handlePlayNotification(mk(fake, NOW), voidMsg(t1));
    await handlePlayNotification(mk(fake, NOW + 100 * DAY_MS), voidMsg(t2));
    expect((await ledger(uid))?.purchasesBlocked).not.toBe(true);
  });

  test("the block threshold is configurable (a single refund blocks when blockAfterRefunds = 1)", async () => {
    await setCfg({ refundPolicy: { blockAfterRefunds: 1, windowDays: 90 } });
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    await handlePlayNotification(mk(fake), voidMsg(t));
    expect((await ledger(uid))?.purchasesBlocked).toBe(true);
  });

  test("a notification delivered TWICE (or three times) reverses once", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    await spendDownTo(uid, 37_000);
    const results = await Promise.all([1, 2, 3].map(() => handlePlayNotification(mk(fake), voidMsg(t))));
    expect(results.filter((r) => r.handled === "voided:reversed")).toHaveLength(1);
    expect(results.filter((r) => r.handled === "voided:already_reversed")).toHaveLength(2);
    expect((await ledger(uid))?.debtUnits).toBe(50_000); // not 150,000
    expect((await revenue())?.rolling12mKwacha).toBe(0);
  });

  test("a refund for a token we never credited is audited and changes nothing", async () => {
    const r = await handlePlayNotification(mk(new FakePlay("x")), voidMsg("a-token-we-never-saw-0123456789"));
    expect(r.handled).toBe("voided:unknown_purchase");
    expect(await auditSteps()).toContain("void_unknown_purchase");
    expect((await db.collection("processedPurchases").get()).size).toBe(0);
  });

  test("notifications for another app, unreadable ones, Google's test ping and subscription voids are ignored safely (never thrown, which would loop forever)", async () => {
    const deps = mk(new FakePlay("x"));
    expect((await handlePlayNotification(deps, { packageName: "com.someone.else", voidedPurchaseNotification: { purchaseToken: "t" } })).handled).toBe("wrong_package");
    expect((await handlePlayNotification(deps, "not json {{{")).handled).toBe("unreadable");
    expect((await handlePlayNotification(deps, undefined)).handled).toBe("unreadable");
    expect((await handlePlayNotification(deps, { packageName: PLAY_PACKAGE_NAME, testNotification: { version: "1.0" } })).handled).toBe("test");
    expect((await handlePlayNotification(deps, voidMsg("some-subscription-token-0123456789", { productType: 1 }))).handled).toBe("subscription_ignored");
    expect((await handlePlayNotification(deps, { packageName: PLAY_PACKAGE_NAME, voidedPurchaseNotification: {} })).handled).toBe("void_without_token");
    expect((await handlePlayNotification(deps, { packageName: PLAY_PACKAGE_NAME, pendingRefundReviewNotification: {} })).handled).toBe("other");
  });

  test("a message delivered as a JSON STRING (as Pub/Sub carries it) works too", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    const r = await handlePlayNotification(mk(fake), JSON.stringify(voidMsg(t)));
    expect(r.handled).toBe("voided:reversed");
  });

  test("a QUANTITY-BASED partial refund is not guessed at: flagged for a manual look, credits untouched", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    const r = await handlePlayNotification(mk(fake), voidMsg(t, { refundType: 2 }));
    expect(r.handled).toBe("voided:needs_manual_review");
    expect((await ledger(uid))?.purchasedUnits).toBe(87_000);
    expect(await anomalyTypes()).toContain("partial_refund_manual_review");
    expect(notifications[0].subject).toMatch(/partial refund/);
  });

  test("a one-time-product CANCELED notification for a credited purchase reverses it; for an unknown one it is just logged", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t });
    const cancel = (token: string) => ({ packageName: PLAY_PACKAGE_NAME, oneTimeProductNotification: { version: "1.0", notificationType: 2, purchaseToken: token, sku: "marking_bundle_k50" } });
    expect((await handlePlayNotification(mk(fake), cancel(t))).handled).toBe("canceled:reversed");
    expect((await ledger(uid))?.purchasedUnits).toBe(0);
    expect((await handlePlayNotification(mk(fake), cancel("an-unknown-token-0123456789"))).handled).toBe("one_time_logged");
  });

  test("the daily RECONCILIATION reverses a refund whose notification never arrived, and skips ones already handled", async () => {
    const uid = newUid();
    const [t1, t2] = [tokenFor(uid, "1"), tokenFor(uid, "2")];
    const fake = new FakePlay(uid);
    await buy(fake, uid, { token: t1 });
    await buy(fake, uid, { token: t2 });
    await handlePlayNotification(mk(fake), voidMsg(t1)); // this one DID arrive
    fake.voided = [
      { purchaseToken: t1, orderId: "o1", voidedTimeMillis: NOW, voidedQuantity: null, voidedReason: 1, voidedSource: 0 },
      { purchaseToken: t2, orderId: "o2", voidedTimeMillis: NOW, voidedQuantity: null, voidedReason: 7, voidedSource: 2 }, // chargeback; the notification was missed
      { purchaseToken: "never-ours-token-0123456789", orderId: "o3", voidedTimeMillis: NOW, voidedQuantity: null, voidedReason: 0, voidedSource: 0 },
    ];
    const r = await reconcileVoidedPurchases(mk(fake));
    expect(r).toMatchObject({ checked: 3, reversed: 1, truncated: false });
    expect((await processed(t2))?.status).toBe("voided");
    expect(fake.calls.listVoided).toBe(1);
  });

  test("if Google says there are MORE voided purchases than one page, the reconciliation records that it was incomplete", async () => {
    const fake = new FakePlay("x");
    fake.voidedTruncated = true;
    const r = await reconcileVoidedPurchases(mk(fake));
    expect(r.truncated).toBe(true);
    const done = (await auditDocs()).find((d) => d.step === "reconcile_done");
    expect(done).toMatchObject({ outcome: "error", detail: { truncated: true } });
  });
});

// ======================================================================== 4e
describe("4e — rate limiting and anomaly flagging", () => {
  test("a burst of verification calls is FLAGGED once (at the 8th in the window), not blocked", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.verifyError = new PlayVerificationError("invalid", "no such token");
    for (let i = 0; i < PURCHASE_RATE.flagAt + 5; i++) {
      await expect(buy(fake, uid, { token: tokenFor(uid, `r${i}`) })).rejects.toMatchObject({ code: "invalid-argument" }); // still answered, never blocked
    }
    expect((await anomalyTypes()).filter((t) => t === "rate_high")).toHaveLength(1);
  });

  test("far beyond any honest use the call is refused (protecting Google's API quota), and a NEW window starts clean", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.verifyError = new PlayVerificationError("invalid", "x");
    for (let i = 0; i < PURCHASE_RATE.blockAt; i++) await buy(fake, uid, { token: tokenFor(uid, `b${i}`) }).catch(() => undefined);
    await expect(buy(fake, uid, { token: tokenFor(uid, "over") })).rejects.toMatchObject({ code: "resource-exhausted" });
    const later = NOW + PURCHASE_RATE.windowMs + 1000;
    await expect(buy(fake, uid, { token: tokenFor(uid, "later"), nowMs: later })).rejects.toMatchObject({ code: "invalid-argument" });
  });

  test("the limit is per account: one busy account doesn't affect another", async () => {
    const busy = newUid();
    const calm = newUid();
    const fb = new FakePlay(busy);
    fb.verifyError = new PlayVerificationError("invalid", "x");
    for (let i = 0; i <= PURCHASE_RATE.blockAt; i++) await buy(fb, busy, { token: tokenFor(busy, `p${i}`) }).catch(() => undefined);
    await expect(buy(new FakePlay(calm), calm)).resolves.toMatchObject({ creditsGranted: 87 });
  });
});

// ======================================================================== 4f
describe("4f — audit trail", () => {
  test("a successful purchase leaves every step in purchaseAuditLog, each carrying the account, product, order and token HASH", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    await buy(new FakePlay(uid), uid, { token: t });
    const key = hashId(t);
    const mine = (await auditDocs()).filter((d) => d.purchaseKey === key);
    const steps = mine.map((d) => d.step);
    for (const expected of ["token_received", "verified", "price_checked", "credited", "revenue_recorded", "ack_sent"]) {
      expect(steps).toContain(expected);
    }
    for (const d of mine) {
      expect(d.uid).toBe(uid);
      expect(d.productId).toBe("marking_bundle_k50");
      expect(typeof d.atMs).toBe("number");
    }
    expect(mine.find((d) => d.step === "credited")).toMatchObject({ outcome: "ok", detail: { creditsGranted: 87, balanceAfter: 87 } });
    expect(mine.find((d) => d.step === "verified")?.orderId).toBe("GPA.0000-1111");
  });

  test("refusals, duplicates, refunds and acknowledgement failures are all recorded too", async () => {
    const uid = newUid();
    const fake = new FakePlay(uid);
    fake.purchase = { purchaseState: 2 };
    const pending = tokenFor(uid, "p");
    await buy(fake, uid, { token: pending }).catch(() => undefined);
    fake.purchase = {};
    fake.ackError = new PlayVerificationError("unavailable", "down");
    const t = tokenFor(uid, "ok");
    await buy(fake, uid, { token: t });
    await buy(fake, uid, { token: t });
    await handlePlayNotification(mk(fake), { packageName: PLAY_PACKAGE_NAME, voidedPurchaseNotification: { purchaseToken: t, productType: 2, refundType: 1 } });

    expect(await auditSteps(hashId(pending))).toContain("purchase_pending");
    const steps = await auditSteps(hashId(t));
    for (const expected of ["credited", "ack_failed", "duplicate", "void_received", "voided_reversal"]) expect(steps).toContain(expected);
    const refusal = (await auditDocs()).find((d) => d.step === "purchase_pending");
    expect(refusal?.outcome).toBe("refused");
  });

  test("NO raw purchase token ever appears in the audit log or the anomaly log", async () => {
    const uid = newUid();
    const t = tokenFor(uid);
    const fake = new FakePlay(uid);
    fake.order = { total: { currency: "ZMW", amount: 5 } }; // provoke an anomaly
    await buy(fake, uid, { token: t }).catch(() => undefined);
    fake.order = {};
    await buy(fake, uid, { token: t });
    await handlePlayNotification(mk(fake), { packageName: PLAY_PACKAGE_NAME, voidedPurchaseNotification: { purchaseToken: t, productType: 2, refundType: 1 } });
    const everything = JSON.stringify([...(await auditDocs()), ...(await db.collection("purchaseAnomalies").get()).docs.map((d) => d.data())]);
    expect(everything.length).toBeGreaterThan(200);
    expect(everything).not.toContain(t);
    expect(everything).not.toContain("SECRET0123456789");
  });
});
