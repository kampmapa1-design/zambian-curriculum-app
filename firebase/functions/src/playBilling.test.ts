import {
  PLAY_PACKAGE_NAME,
  PlayVerificationError,
  createPlayVerifier,
  normalizeMoney,
  normalizePlayOrder,
  normalizePlayPurchase,
  normalizeVoidedPurchases,
} from "./playBilling";

const okJson = (body: unknown, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => body }) as unknown as Response;
const empty = (status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => { throw new Error("no body"); } }) as unknown as Response;
const verifierWith = (fetchFn: typeof fetch) => createPlayVerifier({ fetchFn, getAccessToken: async () => "test-token" });

describe("normalizePlayPurchase", () => {
  test("reads the fields the purchase pipeline depends on", () => {
    expect(
      normalizePlayPurchase({
        purchaseState: 0, consumptionState: 1, acknowledgementState: 1, orderId: "GPA.1", purchaseTimeMillis: "1790000000000",
        regionCode: "ZM", quantity: 2, obfuscatedExternalAccountId: "acct", productId: "marking_bundle_k50", purchaseType: 0,
      })
    ).toEqual({
      purchaseState: 0, consumptionState: 1, acknowledgementState: 1, orderId: "GPA.1", purchaseTimeMillis: 1790000000000,
      regionCode: "ZM", quantity: 2, obfuscatedExternalAccountId: "acct", productId: "marking_bundle_k50", purchaseType: 0,
    });
  });

  test("a missing/garbled purchaseState is -1 (never 0), so it can never be mistaken for 'purchased'", () => {
    for (const raw of [undefined, null, {}, { purchaseState: "0" }]) {
      expect(normalizePlayPurchase(raw).purchaseState).toBe(-1);
    }
  });

  test("defaults: quantity 1, no account id, no product id, no time, an ORDINARY purchase (purchaseType null)", () => {
    const p = normalizePlayPurchase({ purchaseState: 0 });
    expect(p).toMatchObject({ quantity: 1, obfuscatedExternalAccountId: null, productId: null, purchaseTimeMillis: null, orderId: null, purchaseType: null });
  });

  test("purchaseType 0 / 1 / 2 (test, promo, rewarded) is preserved so those are never counted as revenue", () => {
    for (const t of [0, 1, 2]) expect(normalizePlayPurchase({ purchaseState: 0, purchaseType: t }).purchaseType).toBe(t);
  });
});

describe("normalizeMoney — Google's { currencyCode, units (a string), nanos }", () => {
  test("units and nanos combine into one amount", () => {
    expect(normalizeMoney({ currencyCode: "zmw", units: "50", nanos: 0 })).toEqual({ currency: "ZMW", amount: 50 });
    expect(normalizeMoney({ currencyCode: "USD", units: "2", nanos: 500_000_000 })).toEqual({ currency: "USD", amount: 2.5 });
    expect(normalizeMoney({ currencyCode: "USD", nanos: 990_000_000 })).toEqual({ currency: "USD", amount: 0.99 }); // units omitted = 0
  });
  test("garbage gives null, never a fake zero price", () => {
    for (const raw of [null, undefined, {}, { units: "5" }, { currencyCode: "ZMW", units: "lots" }, "K50"]) expect(normalizeMoney(raw)).toBeNull();
  });
});

describe("normalizePlayOrder", () => {
  test("reads state, the amount paid, tax, Google's net figure, line items and country", () => {
    const o = normalizePlayOrder({
      orderId: "GPA.1", state: "PROCESSED",
      total: { currencyCode: "ZMW", units: "50" }, tax: { currencyCode: "ZMW", units: "7", nanos: 0 },
      developerRevenueInBuyerCurrency: { currencyCode: "ZMW", units: "35", nanos: 500_000_000 },
      buyerAddress: { buyerCountry: "ZM" }, lineItems: [{ productId: "marking_bundle_k50" }, { productId: "x" }, {}],
    });
    expect(o).toEqual({
      state: "PROCESSED", total: { currency: "ZMW", amount: 50 }, tax: { currency: "ZMW", amount: 7 },
      developerRevenue: { currency: "ZMW", amount: 35.5 }, lineItemProductIds: ["marking_bundle_k50", "x"], buyerCountry: "ZM",
    });
  });
  test("an empty or odd order has no price rather than a made-up one", () => {
    expect(normalizePlayOrder({})).toEqual({ state: "STATE_UNSPECIFIED", total: null, tax: null, developerRevenue: null, lineItemProductIds: [], buyerCountry: null });
    expect(normalizePlayOrder(null).total).toBeNull();
  });
});

describe("normalizeVoidedPurchases", () => {
  test("reads the list, skips entries with no token, and reports whether Google has another page", () => {
    const r = normalizeVoidedPurchases({
      voidedPurchases: [
        { purchaseToken: "t1", orderId: "o1", voidedTimeMillis: "1790000000000", voidedQuantity: 1, voidedReason: 7, voidedSource: 2 },
        { orderId: "no-token" },
      ],
      tokenPagination: { nextPageToken: "more" },
    });
    expect(r.purchases).toEqual([{ purchaseToken: "t1", orderId: "o1", voidedTimeMillis: 1790000000000, voidedQuantity: 1, voidedReason: 7, voidedSource: 2 }]);
    expect(r.truncated).toBe(true);
  });
  test("an empty answer is an empty list, not truncated", () => {
    expect(normalizeVoidedPurchases({})).toEqual({ purchases: [], truncated: false });
  });
});

describe("createPlayVerifier — the requests actually sent to Google", () => {
  const recorder = (respond: () => Response = () => okJson({ purchaseState: 0 })) => {
    const seen: { url: string; init: RequestInit }[] = [];
    const fetchFn = (async (url: string, init: RequestInit) => {
      seen.push({ url, init });
      return respond();
    }) as unknown as typeof fetch;
    return { seen, v: verifierWith(fetchFn) };
  };

  test("verify: GET the products endpoint for OUR package, bearer-authenticated, token URL-encoded", async () => {
    const { seen, v } = recorder();
    await v.verify("marking_bundle_k50", "tok/en+with=odd chars");
    expect(seen[0].url).toContain(`/applications/${PLAY_PACKAGE_NAME}/purchases/products/marking_bundle_k50/tokens/`);
    expect(seen[0].url).toContain(encodeURIComponent("tok/en+with=odd chars"));
    expect(seen[0].url.endsWith(":acknowledge")).toBe(false);
    expect(seen[0].init.method).toBe("GET");
    expect((seen[0].init.headers as Record<string, string>).Authorization).toBe("Bearer test-token");
  });

  test("acknowledge: POST to the :acknowledge action on the same token URL, with a JSON body", async () => {
    const { seen, v } = recorder(() => empty(204));
    await v.acknowledge("marking_bundle_k50", "abc/def");
    expect(seen[0].url).toContain(`/purchases/products/marking_bundle_k50/tokens/${encodeURIComponent("abc/def")}:acknowledge`);
    expect(seen[0].init.method).toBe("POST");
    expect(seen[0].init.body).toBe("{}");
    expect((seen[0].init.headers as Record<string, string>)["Content-Type"]).toBe("application/json");
    expect((seen[0].init.headers as Record<string, string>).Authorization).toBe("Bearer test-token");
  });

  test("acknowledge succeeds on an empty 200/204 reply (Google returns no body)", async () => {
    for (const status of [200, 204]) {
      const { v } = recorder(() => empty(status));
      await expect(v.acknowledge("p", "t")).resolves.toBeUndefined();
    }
  });

  test("getOrder: GET the orders endpoint by order id, and return the amount paid", async () => {
    const { seen, v } = recorder(() => okJson({ state: "PROCESSED", total: { currencyCode: "ZMW", units: "50" } }));
    const o = await v.getOrder("GPA.3373-1111-2222");
    expect(seen[0].url).toContain(`/applications/${PLAY_PACKAGE_NAME}/orders/${encodeURIComponent("GPA.3373-1111-2222")}`);
    expect(seen[0].init.method).toBe("GET");
    expect(o.total).toEqual({ currency: "ZMW", amount: 50 });
  });

  test("listVoidedPurchases: GET the voided list for the window, in-app products only, one big page", async () => {
    const { seen, v } = recorder(() => okJson({ voidedPurchases: [{ purchaseToken: "t" }] }));
    const r = await v.listVoidedPurchases(1_000, 2_000);
    expect(seen[0].url).toContain(`/applications/${PLAY_PACKAGE_NAME}/purchases/voidedpurchases?startTime=1000&endTime=2000&maxResults=1000&type=0`);
    expect(r.purchases).toHaveLength(1);
  });

  const kindFor = async (status: number, call: (v: ReturnType<typeof verifierWith>) => Promise<unknown>) => {
    const v = verifierWith((async () => okJson({}, status)) as unknown as typeof fetch);
    try {
      await call(v);
    } catch (e) {
      return (e as PlayVerificationError).kind;
    }
    return "no-error";
  };
  const everyCall: [string, (v: ReturnType<typeof verifierWith>) => Promise<unknown>][] = [
    ["verify", (v) => v.verify("p", "t")],
    ["acknowledge", (v) => v.acknowledge("p", "t")],
    ["getOrder", (v) => v.getOrder("o")],
    ["listVoidedPurchases", (v) => v.listVoidedPurchases(1, 2)],
  ];

  test.each(everyCall)("%s: 401/403 -> unauthorized (API access not set up: fail closed)", async (_n, call) => {
    expect(await kindFor(401, call)).toBe("unauthorized");
    expect(await kindFor(403, call)).toBe("unauthorized");
  });
  test.each(everyCall)("%s: 400/404/410 -> invalid", async (_n, call) => {
    for (const s of [400, 404, 410]) expect(await kindFor(s, call)).toBe("invalid");
  });
  test.each(everyCall)("%s: 5xx -> unavailable (transient)", async (_n, call) => {
    expect(await kindFor(500, call)).toBe("unavailable");
    expect(await kindFor(503, call)).toBe("unavailable");
  });

  test("a network failure -> unavailable, not a crash", async () => {
    const v = verifierWith((async () => { throw new Error("ENOTFOUND"); }) as unknown as typeof fetch);
    await expect(v.verify("p", "t")).rejects.toMatchObject({ kind: "unavailable" });
    await expect(v.acknowledge("p", "t")).rejects.toMatchObject({ kind: "unavailable" });
  });

  test("failing to obtain an access token is reported as unauthorized, not swallowed", async () => {
    const v = createPlayVerifier({
      fetchFn: (async () => okJson({})) as unknown as typeof fetch,
      getAccessToken: async () => { throw new PlayVerificationError("unauthorized", "no creds"); },
    });
    await expect(v.verify("p", "t")).rejects.toMatchObject({ kind: "unauthorized" });
  });
});
