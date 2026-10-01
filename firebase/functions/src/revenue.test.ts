import { DEFAULT_MARKING_CREDITS_CONFIG } from "./credits";
import {
  DAY_MS,
  FX_STALE_DAYS,
  buildFinanceSummary,
  fxStatus,
  isOwnerUid,
  parseOwnerSettings,
  rollingTotal,
  toKwacha,
} from "./revenue";

const NOW = Date.parse("2026-09-19T10:00:00Z");

describe("toKwacha", () => {
  test("kwacha passes through, USD converts at the stored rate, anything else is unknown (never guessed)", () => {
    expect(toKwacha(50, "ZMW", 20)).toBe(50);
    expect(toKwacha(2.5, "USD", 20)).toBe(50);
    expect(toKwacha(2.5, "usd", 24)).toBe(60);
    expect(toKwacha(10, "EUR", 20)).toBeNull();
  });
});

describe("rollingTotal", () => {
  test("counts events in the trailing 365 days only; boundary and future events excluded", () => {
    const events = [
      { atMs: NOW - 366 * DAY_MS, amountKwacha: 1000 }, // too old
      { atMs: NOW - 365 * DAY_MS, amountKwacha: 500 }, // exactly at the edge: excluded
      { atMs: NOW - 364 * DAY_MS, amountKwacha: 100 },
      { atMs: NOW, amountKwacha: 50 },
      { atMs: NOW + 1, amountKwacha: 9999 }, // future
    ];
    expect(rollingTotal(events, NOW)).toBe(150);
  });
});

describe("parseOwnerSettings", () => {
  test("empty/garbage settings give safe defaults: nobody is owner, FX K20, threshold K800,000", () => {
    for (const raw of [undefined, {}, { ownerUids: "me", vatThresholdKwacha: -1, fxUsdToZmw: { rate: 0 } }]) {
      const s = parseOwnerSettings(raw as never);
      expect(s.ownerUids).toEqual([]);
      expect(s.fxUsdToZmw).toEqual({ rate: 20, updatedAtMs: null });
      expect(s.vatThresholdKwacha).toBe(800_000);
      expect(s.ownerEmail).toBeNull();
    }
  });

  test("valid values are read, and only string uids count as owners", () => {
    const s = parseOwnerSettings({ ownerUids: ["a", 3, "", "b"], ownerEmail: "o@x.com", fxUsdToZmw: { rate: 25, updatedAtMs: 5 }, vatThresholdKwacha: 1_000_000 });
    expect(s.ownerUids).toEqual(["a", "b"]);
    expect(isOwnerUid(s, "a")).toBe(true);
    expect(isOwnerUid(s, "zzz")).toBe(false);
    expect(s.fxUsdToZmw).toEqual({ rate: 25, updatedAtMs: 5 });
    expect(s.vatThresholdKwacha).toBe(1_000_000);
  });
});

describe("fxStatus — the 60-day staleness flag", () => {
  const settings = (updatedAtMs: number | null) => parseOwnerSettings({ fxUsdToZmw: { rate: 22, updatedAtMs } });

  test("never updated counts as stale", () => {
    expect(fxStatus(settings(null), NOW)).toMatchObject({ stale: true, daysSinceUpdate: null, rate: 22 });
  });
  test("60 days is fine, 61 is stale", () => {
    expect(fxStatus(settings(NOW - FX_STALE_DAYS * DAY_MS), NOW).stale).toBe(false);
    expect(fxStatus(settings(NOW - (FX_STALE_DAYS + 1) * DAY_MS), NOW).stale).toBe(true);
  });
});

describe("buildFinanceSummary", () => {
  const settings = parseOwnerSettings({});
  const cfg = JSON.parse(JSON.stringify(DEFAULT_MARKING_CREDITS_CONFIG));

  test("with no data at all: zero revenue, full distance to threshold, null (not zero) cost-per-page", () => {
    const s = buildFinanceSummary({ settings, revenue: undefined, usageAgg: undefined, cfg, nowMs: NOW });
    expect(s.revenue).toMatchObject({ rolling12mKwacha: 0, remainingKwacha: 800_000, vatThresholdCrossed: false });
    expect(s.usage.concise.measuredCostPerPageUsd).toBeNull();
    expect(s.usage.concise.measuredVsModeled).toBeNull();
  });

  test("remaining distance never goes negative once past the threshold", () => {
    const s = buildFinanceSummary({ settings, revenue: { rolling12mKwacha: 900_000, vatThresholdCrossed: true }, usageAgg: undefined, cfg, nowMs: NOW });
    expect(s.revenue.remainingKwacha).toBe(0);
    expect(s.revenue.percentOfThreshold).toBeCloseTo(112.5, 5);
  });

  test("the 2027 price change shows as the upcoming weights, then as the active ones", () => {
    const before = buildFinanceSummary({ settings, revenue: undefined, usageAgg: undefined, cfg, nowMs: NOW });
    expect(before.config.activeWeights.concise).toBe(3.2);
    expect(before.config.nextWeights?.concise).toBe(6.4);
    const after = buildFinanceSummary({ settings, revenue: undefined, usageAgg: undefined, cfg, nowMs: Date.parse("2027-01-02T00:00:00Z") });
    expect(after.config.activeWeights.concise).toBe(6.4);
    expect(after.config.nextWeights).toBeNull();
  });

  test("measured cost per page divides ALL attempt cost (retries included) by successful pages", () => {
    const s = buildFinanceSummary({
      settings, revenue: undefined, cfg, nowMs: NOW,
      usageAgg: { engines: { stable: { attempts: 3, successes: 2, pagesSuccessful: 8, costUsd: 0.03, unpricedAttempts: 0 } } },
    });
    expect(s.usage.stable.measuredCostPerPageUsd).toBeCloseTo(0.00375, 8);
    expect(s.usage.stable.measuredVsModeled).toBeCloseTo(0.00375 / 0.0026, 5);
  });
});
