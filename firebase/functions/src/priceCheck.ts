// Price check for a verified purchase (Stage 4a/4e).
//
// Google's purchase lookup carries no price, so the amount actually paid comes
// from the Orders API. The client sends no price at all, so a mismatch is never
// "the phone lied": it means the Play Console price differs from the configured
// bundle price, a promotion or discount applied, or a bug - all worth knowing
// about, none safe to accept silently.
import type { PlayMoney, PlayOrder } from "./playBilling";

export type PriceStatus =
  /** Paid what the bundle costs (within tolerance). */
  | "match"
  /** Paid clearly MORE than the bundle price (same currency). */
  | "over"
  /** Paid clearly LESS than the bundle price (same currency) - the dangerous one. */
  | "under"
  /** Paid in a different currency, so no honest comparison is possible (e.g. a buyer abroad). */
  | "currency_differs"
  /** The order could not be read, so the price is unknown. */
  | "unavailable"
  /** A test, promo or rewarded purchase - not a real payment, so there is no price to compare. */
  | "skipped_nonpaid";

export interface PriceVerdict {
  status: PriceStatus;
  expected: PlayMoney;
  observed: PlayMoney | null;
  /** (observed - expected) / expected, percent; only for same-currency comparisons. */
  differencePercent: number | null;
}

/**
 * Compare what Google says was paid with what the bundle should cost.
 * [expected] is the bundle's list price for ONE unit; it is multiplied by [quantity].
 */
export function evaluatePrice(args: {
  expected: PlayMoney;
  quantity: number;
  order: PlayOrder | null;
  purchaseType: number | null;
  tolerancePercent: number;
}): PriceVerdict {
  const expected: PlayMoney = { currency: args.expected.currency.toUpperCase(), amount: args.expected.amount * args.quantity };
  const base = { expected, observed: null as PlayMoney | null, differencePercent: null as number | null };

  if (args.purchaseType !== null) return { ...base, status: "skipped_nonpaid" };
  const rawObserved = args.order?.total ?? null;
  if (!rawObserved) return { ...base, status: "unavailable" };
  // Normalize defensively — normalizePlayOrder already uppercases, but this must not
  // silently misfire (a false "currency_differs" would hold a genuinely fine purchase)
  // if it is ever called with an order that wasn't built through that path.
  const observed: PlayMoney = { currency: rawObserved.currency.toUpperCase(), amount: rawObserved.amount };
  if (observed.currency !== expected.currency) return { ...base, status: "currency_differs", observed };

  const diff = expected.amount > 0 ? ((observed.amount - expected.amount) / expected.amount) * 100 : 0;
  const status: PriceStatus = diff < -args.tolerancePercent ? "under" : diff > args.tolerancePercent ? "over" : "match";
  return { status, expected, observed, differencePercent: Math.round(diff * 100) / 100 };
}
