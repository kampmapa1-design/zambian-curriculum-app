// Unit tests for the PURE half of credits.ts (no Firestore). The transaction
// half — exactly-once charging, idempotent purchases, concurrency — is in
// credits.int.test.ts against the local Firestore emulator.
import {
  DEFAULT_MARKING_CREDITS_CONFIG,
  UNITS_PER_CREDIT,
  activeBundles,
  applySpend,
  availableUnits,
  creditUnitsForCall,
  detectEngine,
  featureWeight,
  emptyLedger,
  hashId,
  parseMarkingCreditsConfig,
  periodKeyCAT,
  rollFreeAllowance,
  selectWeightSet,
  toUnits,
  userOwnerKey,
  type MarkingCreditsConfig,
} from "./credits";

const cfg = (): MarkingCreditsConfig => JSON.parse(JSON.stringify(DEFAULT_MARKING_CREDITS_CONFIG));

describe("parseMarkingCreditsConfig", () => {
  test("missing or garbage config falls back to the safe defaults — mode OFF", () => {
    for (const raw of [undefined, null, 42, "x", []]) {
      const c = parseMarkingCreditsConfig(raw);
      expect(c.mode).toBe("off");
      expect(c.freeMonthlyCredits).toBe(10);
      expect(c.weightSets).toHaveLength(2);
    }
  });

  test("valid remote values override the defaults", () => {
    const c = parseMarkingCreditsConfig({ mode: "enforced", freeMonthlyCredits: 30 });
    expect(c.mode).toBe("enforced");
    expect(c.freeMonthlyCredits).toBe(30);
  });

  test("an invalid mode or negative allowance is ignored, not trusted", () => {
    const c = parseMarkingCreditsConfig({ mode: "yes please", freeMonthlyCredits: -5 });
    expect(c.mode).toBe("off");
    expect(c.freeMonthlyCredits).toBe(10);
  });

  test("weight sets: entries missing an engine or with a bad date are dropped; the rest are sorted by date", () => {
    const c = parseMarkingCreditsConfig({
      weightSets: [
        { effectiveFrom: "2027-01-01T00:00:00+02:00", weights: { stable: 1, concise: 6.4, keyed: 6.5 } },
        { effectiveFrom: "not a date", weights: { stable: 1, concise: 1, keyed: 1 } },
        { effectiveFrom: "2026-10-01T00:00:00+02:00", weights: { stable: 1, concise: 3 } }, // keyed missing
        { effectiveFrom: "2026-06-01T00:00:00+02:00", weights: { stable: 1, concise: 3.2, keyed: 3.3 } },
      ],
    });
    expect(c.weightSets.map((s) => s.effectiveFrom)).toEqual(["2026-06-01T00:00:00+02:00", "2027-01-01T00:00:00+02:00"]);
  });

  test("a zero or negative weight is rejected (it would make marking free)", () => {
    const c = parseMarkingCreditsConfig({
      weightSets: [{ effectiveFrom: "2026-06-01T00:00:00+02:00", weights: { stable: 0, concise: 3, keyed: 3 } }],
    });
    expect(c.weightSets).toEqual(DEFAULT_MARKING_CREDITS_CONFIG.weightSets);
  });

  test("bundles: invalid products are dropped, an explicit null scenario is preserved", () => {
    const c = parseMarkingCreditsConfig({
      bundles: {
        activeScenario: "scenario1",
        scenarios: {
          scenario1: {
            good: { credits: 100, listPrice: { amount: 50, currency: "ZMW" } },
            noCredits: { listPrice: { amount: 50, currency: "ZMW" } },
            zeroPrice: { credits: 10, listPrice: { amount: 0, currency: "ZMW" } },
          },
          scenario2: null,
        },
      },
    });
    expect(Object.keys(c.bundles.scenarios.scenario1 ?? {})).toEqual(["good"]);
    expect(c.bundles.scenarios.scenario2).toBeNull();
  });
});

describe("selectWeightSet — server time decides, and the switch is exact", () => {
  const c = cfg();
  const jan1Cat = Date.parse("2027-01-01T00:00:00+02:00"); // = 2026-12-31T22:00:00Z

  test("uses the 2026 weights (Concise 3.2) before 1 Jan 2027", () => {
    expect(selectWeightSet(c, Date.parse("2026-11-15T12:00:00Z")).weights.concise).toBe(3.2);
  });

  test("switches to the 2027 weights (Concise 6.4, Key-based 6.5, Stable unchanged) at exactly midnight CAT", () => {
    expect(selectWeightSet(c, jan1Cat - 1).weights.concise).toBe(3.2);
    const w = selectWeightSet(c, jan1Cat).weights;
    expect(w).toEqual({ stable: 1, concise: 6.4, keyed: 6.5 });
  });

  test("a time before the first effective date safely uses the earliest set", () => {
    expect(selectWeightSet(c, Date.parse("2020-01-01T00:00:00Z")).weights.stable).toBe(1);
  });
});

describe("engine detection and pricing units", () => {
  test("lightweight = Stable; a supplied key = Key-based; otherwise Concise", () => {
    expect(detectEngine({ lightweight: true })).toBe("stable");
    expect(detectEngine({ lightweight: true, hasMarkingKey: true })).toBe("stable");
    expect(detectEngine({ hasMarkingKey: true })).toBe("keyed");
    expect(detectEngine({})).toBe("concise");
  });

  test("4 Concise pages at 3.2 credits/page = exactly 12.8 credits", () => {
    expect(creditUnitsForCall(3.2, 4)).toBe(12_800);
    expect(creditUnitsForCall(3.2, 4) / UNITS_PER_CREDIT).toBe(12.8);
  });

  test("floating-point traps round cleanly: 3.3 x 3 pages is 9.9 credits, not 9.899999999999999", () => {
    expect(3.3 * 3).not.toBe(9.9); // the trap this guards against
    expect(creditUnitsForCall(3.3, 3)).toBe(9_900);
  });

  test("toUnits rounds to the nearest unit", () => {
    expect(toUnits(0.0004)).toBe(0);
    expect(toUnits(87)).toBe(87_000);
  });
});

describe("periodKeyCAT — the free allowance resets on Zambian calendar months", () => {
  test("mid-month", () => {
    expect(periodKeyCAT(Date.parse("2026-09-19T10:00:00Z"))).toBe("2026-09");
  });

  test("23:59:59 CAT on 31 Dec is still December; the next second is January", () => {
    expect(periodKeyCAT(Date.parse("2026-12-31T21:59:59Z"))).toBe("2026-12"); // 23:59:59 CAT
    expect(periodKeyCAT(Date.parse("2026-12-31T22:00:00Z"))).toBe("2027-01"); // 00:00:00 CAT
  });

  test("UTC still says the old month for two hours after Zambia has rolled over", () => {
    const t = Date.parse("2026-09-30T23:30:00Z"); // 01:30 CAT on 1 Oct
    expect(new Date(t).getUTCMonth() + 1).toBe(9);
    expect(periodKeyCAT(t)).toBe("2026-10");
  });
});

describe("rollFreeAllowance", () => {
  const now = Date.parse("2026-09-19T10:00:00Z");

  test("first ever call grants the monthly allowance", () => {
    const r = rollFreeAllowance(emptyLedger(), cfg(), now);
    expect(r.granted).toBe(10_000);
    expect(r.expired).toBe(0);
    expect(r.state.freePeriod).toBe("2026-09");
  });

  test("same month: nothing changes", () => {
    const state = { purchasedUnits: 5_000, freeUnits: 3_000, freePeriod: "2026-09" };
    const r = rollFreeAllowance(state, cfg(), now);
    expect(r.state).toEqual(state);
    expect(r.granted).toBe(0);
  });

  test("new month: unused free credits EXPIRE (no roll-over) and a fresh allowance is granted; purchased credits are untouched", () => {
    const state = { purchasedUnits: 50_000, freeUnits: 15_000, freePeriod: "2026-08" };
    const r = rollFreeAllowance(state, cfg(), now);
    expect(r.expired).toBe(15_000);
    expect(r.state.freeUnits).toBe(10_000); // 10, NOT 25
    expect(r.state.purchasedUnits).toBe(50_000);
  });

  test("the allowance size is config-driven", () => {
    const c = cfg();
    c.freeMonthlyCredits = 7.5;
    expect(rollFreeAllowance(emptyLedger(), c, now).state.freeUnits).toBe(7_500);
  });
});

describe("applySpend — free credits go first, then purchased", () => {
  const state = { purchasedUnits: 10_000, freeUnits: 4_000, freePeriod: "2026-09" };

  test("spend smaller than the free balance touches only free credits", () => {
    const r = applySpend(state, 3_000);
    expect(r.fromFree).toBe(3_000);
    expect(r.fromPurchased).toBe(0);
    expect(r.state.freeUnits).toBe(1_000);
    expect(r.state.purchasedUnits).toBe(10_000);
    expect(r.shortfall).toBe(0);
  });

  test("spend larger than free spills into purchased", () => {
    const r = applySpend(state, 9_000);
    expect(r.fromFree).toBe(4_000);
    expect(r.fromPurchased).toBe(5_000);
    expect(availableUnits(r.state)).toBe(5_000);
  });

  test("spend larger than the whole balance drains it to exactly zero and reports the shortfall — never negative", () => {
    const r = applySpend(state, 20_000);
    expect(r.state.freeUnits).toBe(0);
    expect(r.state.purchasedUnits).toBe(0);
    expect(r.shortfall).toBe(6_000);
  });
});

describe("activeBundles", () => {
  test("uses the active scenario", () => {
    expect(Object.keys(activeBundles(cfg()))).toEqual(["marking_bundle_k50", "marking_bundle_k100", "marking_bundle_k150"]);
  });

  test("a null scenario2 (not defined yet) safely falls back to scenario1 instead of selling nothing", () => {
    const c = cfg();
    c.bundles.activeScenario = "scenario2";
    expect(Object.keys(activeBundles(c))).toHaveLength(3);
  });
});

describe("ids", () => {
  test("owner key is namespaced by owner type", () => {
    expect(userOwnerKey("abc")).toBe("user_abc");
  });

  test("hashed request ids are always safe Firestore ids, even for hostile input", () => {
    const id = hashId("a/b/../c   ../../etc");
    expect(id).toMatch(/^[0-9a-f]{40}$/);
    expect(hashId("same")).toBe(hashId("same"));
  });
});

describe("feature weights and modes (non-marking AI features)", () => {
  test("features start OFF, independent of the marking mode — enforcing marking never silently starts charging lesson plans", () => {
    const c = parseMarkingCreditsConfig({ mode: "enforced" });
    expect(c.mode).toBe("enforced");
    expect(c.featuresMode).toBe("off");
    expect(parseMarkingCreditsConfig({ featuresMode: "enforced" }).featuresMode).toBe("enforced");
    expect(parseMarkingCreditsConfig({ featuresMode: "yes" }).featuresMode).toBe("off");
  });

  test("2026 costs: lesson plan 10, scheme of work 10, transcription 4; tiny utilities are 0 (logged, not charged)", () => {
    const c = cfg();
    const now = Date.parse("2026-10-01T00:00:00Z");
    expect(featureWeight(c, now, "lessonPlan")).toBe(10);
    expect(featureWeight(c, now, "schemeOfWork")).toBe(10);
    expect(featureWeight(c, now, "transcription")).toBe(4);
    expect(featureWeight(c, now, "voiceCommand")).toBe(0);
  });

  test("from midnight 1 Jan 2027 (Zambia time) Flash-based features double; the computed timetable does not", () => {
    const c = cfg();
    const jan1 = Date.parse("2027-01-01T00:00:00+02:00");
    expect(featureWeight(c, jan1 - 1, "lessonPlan")).toBe(10);
    expect(featureWeight(c, jan1, "lessonPlan")).toBe(20);
    expect(featureWeight(c, jan1 - 1, "timetable")).toBe(2);
    expect(featureWeight(c, jan1, "timetable")).toBe(2);
  });

  test("an unknown feature costs 0, so a new function is never charged by accident", () => {
    expect(featureWeight(cfg(), Date.parse("2026-10-01T00:00:00Z"), "somethingNew")).toBe(0);
  });

  test("remote overrides win (>= 0); negative or non-numeric ones are ignored; the rest keep their defaults", () => {
    const c = parseMarkingCreditsConfig({
      weightSets: [
        {
          effectiveFrom: "2026-09-19T00:00:00+02:00",
          weights: { stable: 1, concise: 3.2, keyed: 3.3 },
          features: { lessonPlan: 15, schemeOfWork: -3, teachingNotes: "lots", voiceCommand: 0, brandNew: 2.5 },
        },
      ],
    });
    const now = Date.parse("2026-10-01T00:00:00Z");
    expect(featureWeight(c, now, "lessonPlan")).toBe(15);
    expect(featureWeight(c, now, "schemeOfWork")).toBe(10); // negative ignored -> default
    expect(featureWeight(c, now, "teachingNotes")).toBe(8); // garbage ignored -> default
    expect(featureWeight(c, now, "brandNew")).toBe(2.5);
  });

  test("a weight set that omits `features` entirely still gets the defaults for its era", () => {
    const c = parseMarkingCreditsConfig({
      weightSets: [
        { effectiveFrom: "2026-09-19T00:00:00+02:00", weights: { stable: 1, concise: 3.2, keyed: 3.3 } },
        { effectiveFrom: "2027-01-01T00:00:00+02:00", weights: { stable: 1, concise: 6.4, keyed: 6.5 } },
      ],
    });
    expect(featureWeight(c, Date.parse("2026-10-01T00:00:00Z"), "lessonPlan")).toBe(10);
    expect(featureWeight(c, Date.parse("2027-02-01T00:00:00Z"), "lessonPlan")).toBe(20);
  });
});

describe("ad pass config", () => {
  test("off by default, 5 a day, valid for 24h", () => {
    expect(cfg().adPasses).toEqual({ enabled: false, perDayCap: 5, ttlHours: 24 });
  });
  test("only an explicit `true` enables it; bad numbers fall back", () => {
    expect(parseMarkingCreditsConfig({ adPasses: { enabled: "yes" } }).adPasses.enabled).toBe(false);
    const c = parseMarkingCreditsConfig({ adPasses: { enabled: true, perDayCap: 3.9, ttlHours: -1 } });
    expect(c.adPasses).toEqual({ enabled: true, perDayCap: 3, ttlHours: 24 });
  });
});

describe("school allowances (subscribed schools' included AI usage)", () => {
  test("default: $1 a month for timetable work", () => {
    expect(cfg().schoolAllowancesUsd).toEqual({ timetable: 1 });
  });
  test("remote value overrides; negative or non-numeric are ignored; other groups can be added", () => {
    expect(parseMarkingCreditsConfig({ schoolAllowancesUsd: { timetable: 2.5 } }).schoolAllowancesUsd.timetable).toBe(2.5);
    expect(parseMarkingCreditsConfig({ schoolAllowancesUsd: { timetable: -1 } }).schoolAllowancesUsd.timetable).toBe(1);
    expect(parseMarkingCreditsConfig({ schoolAllowancesUsd: { timetable: "lots" } }).schoolAllowancesUsd.timetable).toBe(1);
    expect(parseMarkingCreditsConfig({ schoolAllowancesUsd: { timetable: 0, reports: 3 } }).schoolAllowancesUsd).toEqual({ timetable: 0, reports: 3 });
  });
});
