import { evaluatePrice } from "./priceCheck";
import type { PlayOrder } from "./playBilling";

const K50 = { currency: "ZMW", amount: 50 };
const order = (amount: number, currency = "ZMW"): PlayOrder => ({
  state: "PROCESSED", total: { currency, amount }, tax: null, developerRevenue: null, lineItemProductIds: [], buyerCountry: "ZM",
});
const check = (o: PlayOrder | null, over: { quantity?: number; purchaseType?: number | null; tolerance?: number; expected?: typeof K50 } = {}) =>
  evaluatePrice({ expected: over.expected ?? K50, quantity: over.quantity ?? 1, order: o, purchaseType: over.purchaseType ?? null, tolerancePercent: over.tolerance ?? 2 });

describe("evaluatePrice", () => {
  test("paying exactly the price is a match", () => {
    expect(check(order(50))).toMatchObject({ status: "match", differencePercent: 0, observed: { currency: "ZMW", amount: 50 } });
  });

  test("within the tolerance either way is still a match (rounding / tax presentation)", () => {
    expect(check(order(49.1)).status).toBe("match"); // -1.8%
    expect(check(order(50.9)).status).toBe("match"); // +1.8%
  });

  test("clearly UNDER the price is 'under' - the dangerous case", () => {
    const v = check(order(30));
    expect(v.status).toBe("under");
    expect(v.differencePercent).toBe(-40);
  });

  test("clearly OVER the price is 'over'", () => {
    expect(check(order(75)).status).toBe("over");
  });

  test("the tolerance edge: exactly 2% under is still a match, a hair beyond is under", () => {
    expect(check(order(49)).status).toBe("match");
    expect(check(order(48.99)).status).toBe("under");
  });

  test("a different currency can't be compared honestly", () => {
    const v = check(order(2.5, "USD"));
    expect(v.status).toBe("currency_differs");
    expect(v.observed).toEqual({ currency: "USD", amount: 2.5 });
    expect(v.differencePercent).toBeNull();
  });

  test("currency codes compare case-insensitively", () => {
    expect(check(order(50, "zmw"), { expected: { currency: "zmw", amount: 50 } }).status).toBe("match");
  });

  test("no order (or an order with no total) means the price is UNKNOWN - never assumed correct", () => {
    expect(check(null).status).toBe("unavailable");
    expect(check({ ...order(50), total: null }).status).toBe("unavailable");
  });

  test("test / promo / rewarded purchases have no real payment to compare", () => {
    for (const t of [0, 1, 2]) expect(check(order(0), { purchaseType: t }).status).toBe("skipped_nonpaid");
  });

  test("quantity multiplies the expected price (2 bundles = K100)", () => {
    expect(check(order(100), { quantity: 2 }).status).toBe("match");
    expect(check(order(50), { quantity: 2 }).status).toBe("under");
    expect(check(order(100), { quantity: 2 }).expected.amount).toBe(100);
  });

  test("a zero tolerance is exact", () => {
    expect(check(order(49.99), { tolerance: 0 }).status).toBe("under");
    expect(check(order(50), { tolerance: 0 }).status).toBe("match");
  });
});
