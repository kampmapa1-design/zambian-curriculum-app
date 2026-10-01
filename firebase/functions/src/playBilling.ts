// Server-side dealings with Google Play for one-time purchases (Monetization
// Stage 4). The app NEVER credits itself from a purchase result the phone
// reports: it sends the purchase token here, and this asks Google directly.
//
// What Google's API does and doesn't tell us (checked against the reference):
//  * purchases.products.get -> purchase state, product id, order id, whether it
//    is acknowledged/consumed, the account id we attached at purchase time,
//    region, and the purchase TYPE (test / promo / rewarded). It returns NO PRICE.
//  * orders.get (by order id) -> the amount actually paid (`total`, tax included),
//    `tax`, the developer's revenue after fees, the order state, and the line
//    items. This is where the price check comes from.
//  * purchases.products.acknowledge -> must be called within 3 days or Google
//    refunds the purchase automatically.
//  * purchases.voidedpurchases.list -> refunds/chargebacks in the last 30 days
//    (the backstop for Real-time Developer Notifications that go missing).
//
// PREREQUISITES (Play Console / Google Cloud - not code):
//  1. The "Google Play Android Developer API" is enabled on this Cloud project.
//  2. Play Console > Users and permissions: the Cloud Functions runtime service
//     account is invited with permission to view financial data and manage orders.
//  3. The three in-app products exist with the ids in the marking-credits config.
// Until those are done, verification fails with kind "unauthorized" and NO
// credits are ever granted - it fails closed.
export const PLAY_PACKAGE_NAME = "com.kampmapa1design.smartteacher";

export interface PlayPurchase {
  /** 0 = purchased, 1 = canceled, 2 = pending. Only 0 may be credited. */
  purchaseState: number;
  /** 0 = yet to be consumed, 1 = consumed. */
  consumptionState: number;
  /** 0 = not acknowledged, 1 = acknowledged. */
  acknowledgementState: number;
  orderId: string | null;
  purchaseTimeMillis: number | null;
  regionCode: string | null;
  quantity: number;
  /** The account id the client attached at purchase time (we send a hash of the Firebase uid). */
  obfuscatedExternalAccountId: string | null;
  /** The product id Google says this token is for. */
  productId: string | null;
  /** null = an ordinary paid purchase; 0 = test (licence tester), 1 = promo code, 2 = rewarded. */
  purchaseType: number | null;
}

export interface PlayMoney {
  currency: string;
  amount: number;
}

export interface PlayOrder {
  /** PENDING | PROCESSED | CANCELED | PENDING_REFUND | PARTIALLY_REFUNDED | REFUNDED (| STATE_UNSPECIFIED) */
  state: string;
  /** The final amount paid by the customer, discounts and taxes included. */
  total: PlayMoney | null;
  tax: PlayMoney | null;
  /** What the developer receives after taxes and Google's fee, in the buyer's currency. */
  developerRevenue: PlayMoney | null;
  lineItemProductIds: string[];
  buyerCountry: string | null;
}

export interface VoidedPurchase {
  purchaseToken: string;
  orderId: string | null;
  voidedTimeMillis: number | null;
  voidedQuantity: number | null;
  voidedReason: number | null;
  voidedSource: number | null;
}

export type PlayVerifyFailure = "invalid" | "unauthorized" | "unavailable";

export class PlayVerificationError extends Error {
  constructor(public readonly kind: PlayVerifyFailure, message: string) {
    super(message);
  }
}

export interface PlayVerifier {
  verify(productId: string, purchaseToken: string): Promise<PlayPurchase>;
  /** Acknowledge a purchase (idempotent on Google's side is NOT guaranteed - callers re-check state on error). */
  acknowledge(productId: string, purchaseToken: string): Promise<void>;
  getOrder(orderId: string): Promise<PlayOrder>;
  listVoidedPurchases(startMs: number, endMs: number): Promise<{ purchases: VoidedPurchase[]; truncated: boolean }>;
}

const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);
const int = (v: unknown): number | null => {
  const n = typeof v === "string" ? Number(v) : v;
  return typeof n === "number" && Number.isFinite(n) ? n : null;
};

/** Normalise Google's purchases.products.get response. Pure — unit-tested. */
export function normalizePlayPurchase(raw: unknown): PlayPurchase {
  const r = (raw ?? {}) as Record<string, unknown>;
  const millis = Number(r.purchaseTimeMillis);
  return {
    purchaseState: typeof r.purchaseState === "number" ? r.purchaseState : -1,
    consumptionState: typeof r.consumptionState === "number" ? r.consumptionState : 0,
    acknowledgementState: typeof r.acknowledgementState === "number" ? r.acknowledgementState : 0,
    orderId: str(r.orderId),
    purchaseTimeMillis: Number.isFinite(millis) && millis > 0 ? millis : null,
    regionCode: str(r.regionCode),
    quantity: typeof r.quantity === "number" && r.quantity > 0 ? r.quantity : 1,
    obfuscatedExternalAccountId: str(r.obfuscatedExternalAccountId),
    productId: str(r.productId),
    purchaseType: typeof r.purchaseType === "number" ? r.purchaseType : null,
  };
}

/** Google's Money { currencyCode, units (int64 as a string), nanos } -> a plain amount. */
export function normalizeMoney(raw: unknown): PlayMoney | null {
  const m = (raw ?? null) as Record<string, unknown> | null;
  const currency = str(m?.currencyCode);
  const units = int(m?.units ?? 0);
  const nanos = int(m?.nanos ?? 0);
  if (!currency || units === null || nanos === null) return null;
  return { currency: currency.toUpperCase(), amount: units + nanos / 1e9 };
}

export function normalizePlayOrder(raw: unknown): PlayOrder {
  const r = (raw ?? {}) as Record<string, unknown>;
  const items = Array.isArray(r.lineItems) ? (r.lineItems as Record<string, unknown>[]) : [];
  return {
    state: str(r.state) ?? "STATE_UNSPECIFIED",
    total: normalizeMoney(r.total),
    tax: normalizeMoney(r.tax),
    developerRevenue: normalizeMoney(r.developerRevenueInBuyerCurrency),
    lineItemProductIds: items.map((i) => str(i?.productId)).filter((x): x is string => x !== null),
    buyerCountry: str((r.buyerAddress as Record<string, unknown> | undefined)?.buyerCountry),
  };
}

export function normalizeVoidedPurchases(raw: unknown): { purchases: VoidedPurchase[]; truncated: boolean } {
  const r = (raw ?? {}) as Record<string, unknown>;
  const list = Array.isArray(r.voidedPurchases) ? (r.voidedPurchases as Record<string, unknown>[]) : [];
  const purchases: VoidedPurchase[] = [];
  for (const v of list) {
    const token = str(v?.purchaseToken);
    if (!token) continue;
    purchases.push({
      purchaseToken: token,
      orderId: str(v.orderId),
      voidedTimeMillis: int(v.voidedTimeMillis),
      voidedQuantity: int(v.voidedQuantity),
      voidedReason: int(v.voidedReason),
      voidedSource: int(v.voidedSource),
    });
  }
  const next = str((r.tokenPagination as Record<string, unknown> | undefined)?.nextPageToken);
  return { purchases, truncated: next !== null };
}

export interface PlayVerifierDeps {
  getAccessToken?: () => Promise<string>;
  fetchFn?: typeof fetch;
  packageName?: string;
}

async function defaultAccessToken(): Promise<string> {
  // Loaded lazily: it's already installed (a dependency of firebase-admin) but
  // only needed when Google is really called, never in unit tests.
  const { GoogleAuth } = await import("google-auth-library");
  const auth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/androidpublisher"] });
  const token = await auth.getAccessToken();
  if (!token) throw new PlayVerificationError("unauthorized", "Could not obtain a Google API access token.");
  return token;
}

const API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications";

export function createPlayVerifier(deps: PlayVerifierDeps = {}): PlayVerifier {
  const pkg = encodeURIComponent(deps.packageName ?? PLAY_PACKAGE_NAME);
  const getToken = deps.getAccessToken ?? defaultAccessToken;
  const doFetch = deps.fetchFn ?? fetch;

  /** One authenticated call, with Google's failures mapped to our three kinds. */
  async function call(url: string, init: { method: "GET" | "POST"; body?: string } = { method: "GET" }): Promise<Response> {
    let res: Response;
    try {
      const headers: Record<string, string> = { Authorization: `Bearer ${await getToken()}` };
      if (init.body !== undefined) headers["Content-Type"] = "application/json";
      res = await doFetch(url, { method: init.method, headers, ...(init.body !== undefined ? { body: init.body } : {}) });
    } catch (err) {
      if (err instanceof PlayVerificationError) throw err;
      throw new PlayVerificationError("unavailable", `Could not reach Google Play: ${String(err)}`);
    }
    if (res.status === 401 || res.status === 403) {
      throw new PlayVerificationError(
        "unauthorized",
        "Google Play API access is not set up for this backend (see the prerequisites at the top of playBilling.ts)."
      );
    }
    if (res.status === 400 || res.status === 404 || res.status === 410) {
      throw new PlayVerificationError("invalid", "Google Play does not recognise that request.");
    }
    if (!res.ok) throw new PlayVerificationError("unavailable", `Google Play returned HTTP ${res.status}.`);
    return res;
  }

  const tokenUrl = (productId: string, token: string) =>
    `${API}/${pkg}/purchases/products/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(token)}`;

  return {
    async verify(productId, purchaseToken) {
      return normalizePlayPurchase(await (await call(tokenUrl(productId, purchaseToken))).json());
    },
    async acknowledge(productId, purchaseToken) {
      await call(`${tokenUrl(productId, purchaseToken)}:acknowledge`, { method: "POST", body: "{}" });
    },
    async getOrder(orderId) {
      return normalizePlayOrder(await (await call(`${API}/${pkg}/orders/${encodeURIComponent(orderId)}`)).json());
    },
    async listVoidedPurchases(startMs, endMs) {
      // type=0: in-app products only. One page of up to 1000 is far beyond this app's volume;
      // if Google reports another page the caller is told (`truncated`) so it can narrow the window.
      const q = `startTime=${Math.floor(startMs)}&endTime=${Math.floor(endMs)}&maxResults=1000&type=0`;
      return normalizeVoidedPurchases(await (await call(`${API}/${pkg}/purchases/voidedpurchases?${q}`)).json());
    },
  };
}
