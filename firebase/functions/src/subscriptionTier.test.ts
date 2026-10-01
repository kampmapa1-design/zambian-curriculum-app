// Individual-teacher subscriptions (owner decision, 2026-09-28): a teacher's
// own personal tier now satisfies a Gold+ gate on its own, ORed with the
// existing school-tier check — see `meetsTimetableTier`'s own comment in
// index.ts. This is the pure decision half; the I/O half
// (`fetchAndCheckTimetableTier`) is exercised indirectly by every timetable
// Cloud Function's own emulator/integration coverage, not duplicated here.
import { meetsTimetableTier } from "./index";

describe("meetsTimetableTier", () => {
  it("a Basic school with no personal subscription does NOT meet the gate", () => {
    expect(meetsTimetableTier({ subscriptionTier: "basic" }, undefined)).toBe(false);
  });

  it("a Gold or Institutional school meets the gate on its own, personal tier aside", () => {
    expect(meetsTimetableTier({ subscriptionTier: "gold" }, undefined)).toBe(true);
    expect(meetsTimetableTier({ subscriptionTier: "institutional" }, undefined)).toBe(true);
  });

  it("a teacher's own Gold+ personal subscription meets the gate even at a Basic (or no) school", () => {
    expect(meetsTimetableTier({ subscriptionTier: "basic" }, { tier: "gold" })).toBe(true);
    expect(meetsTimetableTier(undefined, { tier: "institutional" })).toBe(true);
  });

  it("a Basic personal tier does NOT meet the gate on its own", () => {
    expect(meetsTimetableTier(undefined, { tier: "basic" })).toBe(false);
    expect(meetsTimetableTier({ subscriptionTier: "basic" }, { tier: "basic" })).toBe(false);
  });

  it("neither school nor personal data existing at all is treated as Basic/Basic — denied", () => {
    expect(meetsTimetableTier(undefined, undefined)).toBe(false);
  });

  it("the pre-existing institutionalSubscription boolean fallback still works alongside a personal tier check", () => {
    // A school created before `subscriptionTier` existed (see School.fromMap's
    // own fallback) — must still grant access via the legacy boolean, same as
    // before this change, regardless of the (here, absent) personal tier.
    expect(meetsTimetableTier({ institutionalSubscription: true }, undefined)).toBe(true);
  });

  it("an unrecognised personal tier string is treated as Basic, not silently granted", () => {
    expect(meetsTimetableTier(undefined, { tier: "made-up-tier" })).toBe(false);
  });
});
