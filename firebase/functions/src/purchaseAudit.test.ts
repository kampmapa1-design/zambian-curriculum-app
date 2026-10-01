import type { Firestore } from "firebase-admin/firestore";
import { DEFAULT_MARKING_CREDITS_CONFIG, parseMarkingCreditsConfig } from "./credits";
import { auditPurchase, flagPurchaseAnomaly } from "./purchaseAudit";

/** A Firestore stand-in that records what is added, or throws on every write. */
function fakeDb(fail = false) {
  const added: { collection: string; data: Record<string, unknown> }[] = [];
  const db = {
    collection: (name: string) => ({
      add: async (data: Record<string, unknown>) => {
        if (fail) throw new Error("firestore is down");
        added.push({ collection: name, data });
      },
    }),
  } as unknown as Firestore;
  return { db, added };
}

describe("auditPurchase", () => {
  test("a failing audit write NEVER fails the purchase: it is swallowed and reported to the console", async () => {
    const spy = jest.spyOn(console, "error").mockImplementation(() => undefined);
    const { db } = fakeDb(true);
    await expect(auditPurchase(db, { step: "credited", nowMs: 1 })).resolves.toBeUndefined();
    await expect(flagPurchaseAnomaly(db, { type: "rate_high", nowMs: 1 })).resolves.toBeUndefined();
    expect(spy).toHaveBeenCalled();
    spy.mockRestore();
  });

  test("anything called token / purchaseToken is dropped from a log line, whoever passes it", async () => {
    const { db, added } = fakeDb();
    await auditPurchase(db, { step: "x", nowMs: 5, detail: { purchaseToken: "RAW-SECRET", token: "RAW-SECRET-2", PurchaseToken: "RAW-3", ok: 1 } });
    expect(JSON.stringify(added)).not.toContain("RAW");
    expect(added[0].data.detail).toEqual({ ok: 1 });
  });

  test("very long text is truncated, undefined values are omitted (Firestore rejects them)", async () => {
    const { db, added } = fakeDb();
    await auditPurchase(db, { step: "x", nowMs: 5, detail: { big: "y".repeat(5000), missing: undefined } });
    const d = added[0].data.detail as Record<string, string>;
    expect(d.big.length).toBeLessThan(400);
    expect("missing" in d).toBe(false);
  });

  test("an entry records who, what, when and how it ended - defaulting to 'info'", async () => {
    const { db, added } = fakeDb();
    await auditPurchase(db, { step: "verified", uid: "u1", purchaseKey: "k1", productId: "p", orderId: "o", nowMs: 42 });
    expect(added[0]).toMatchObject({ collection: "purchaseAuditLog", data: { step: "verified", outcome: "info", uid: "u1", purchaseKey: "k1", productId: "p", orderId: "o", atMs: 42 } });
  });

  test("an anomaly is filed as 'open' and ALSO written to the audit trail", async () => {
    const { db, added } = fakeDb();
    await flagPurchaseAnomaly(db, { type: "price_underpaid", uid: "u1", purchaseKey: "k1", detail: { status: "under" }, nowMs: 9 });
    expect(added.map((a) => a.collection)).toEqual(["purchaseAnomalies", "purchaseAuditLog"]);
    expect(added[0].data).toMatchObject({ type: "price_underpaid", status: "open", uid: "u1" });
    expect(added[1].data).toMatchObject({ step: "anomaly", detail: { type: "price_underpaid", status: "under" } });
  });
});

describe("purchase and refund policy in the credits config", () => {
  test("defaults: hold an under-payment at 2% tolerance; block after 2 refunds in 90 days", () => {
    const c = parseMarkingCreditsConfig(undefined);
    expect(c.purchasePolicy).toEqual({ priceCheck: "hold", tolerancePercent: 2 });
    expect(c.refundPolicy).toEqual({ blockAfterRefunds: 2, windowDays: 90 });
    expect(c).toMatchObject({ purchasePolicy: DEFAULT_MARKING_CREDITS_CONFIG.purchasePolicy });
  });

  test("valid overrides apply; invalid ones fall back to the safe default", () => {
    const ok = parseMarkingCreditsConfig({ purchasePolicy: { priceCheck: "flag", tolerancePercent: 5 }, refundPolicy: { blockAfterRefunds: 3.9, windowDays: 30 } });
    expect(ok.purchasePolicy).toEqual({ priceCheck: "flag", tolerancePercent: 5 });
    expect(ok.refundPolicy).toEqual({ blockAfterRefunds: 3, windowDays: 30 });
    const bad = parseMarkingCreditsConfig({ purchasePolicy: { priceCheck: "yolo", tolerancePercent: -1 }, refundPolicy: { blockAfterRefunds: 0, windowDays: "many" } });
    expect(bad.purchasePolicy).toEqual({ priceCheck: "hold", tolerancePercent: 2 });
    expect(bad.refundPolicy).toEqual({ blockAfterRefunds: 2, windowDays: 90 });
  });

  test("'off' is a valid price-check setting", () => {
    expect(parseMarkingCreditsConfig({ purchasePolicy: { priceCheck: "off" } }).purchasePolicy.priceCheck).toBe("off");
  });
});
