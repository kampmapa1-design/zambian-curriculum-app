import { DEFAULT_PRICING, buildUsageRecord, estimateCostUsd, extractUsage, hashUid } from "./usageLog";

describe("extractUsage", () => {
  test("reads prompt, output, thinking and image tokens from usageMetadata", () => {
    const u = extractUsage({
      usageMetadata: {
        promptTokenCount: 7480, candidatesTokenCount: 3600, thoughtsTokenCount: 3000, totalTokenCount: 14080,
        promptTokensDetails: [{ modality: "TEXT", tokenCount: 3000 }, { modality: "IMAGE", tokenCount: 4480 }],
      },
    });
    expect(u).toEqual({ promptTokens: 7480, outputTokens: 3600, thinkingTokens: 3000, imageTokens: 4480, totalTokens: 14080 });
  });

  test("sums several image entries (modality matched case-insensitively)", () => {
    const u = extractUsage({ usageMetadata: { promptTokensDetails: [{ modality: "image", tokenCount: 1120 }, { modality: "IMAGE", tokenCount: 1120 }] } });
    expect(u.imageTokens).toBe(2240);
  });

  test("a response with no usage data yields zeros, never NaN or a crash", () => {
    for (const r of [undefined, null, {}, { usageMetadata: {} }, { usageMetadata: { promptTokenCount: "lots" } }]) {
      expect(extractUsage(r)).toEqual({ promptTokens: 0, outputTokens: 0, thinkingTokens: 0, imageTokens: 0, totalTokens: 0 });
    }
  });
});

describe("estimateCostUsd", () => {
  const usage = { promptTokens: 7480, outputTokens: 3600, thinkingTokens: 3000, imageTokens: 4480, totalTokens: 14080 };
  const y2026 = Date.parse("2026-09-19T00:00:00Z");

  test("3.6 Flash, 2026: input at $0.75/M and output INCLUDING thinking at $3.75/M", () => {
    // 7480*0.75 + (3600+3000)*3.75 = 5610 + 24750 = 30360 -> $0.03036
    expect(estimateCostUsd("gemini-3.6-flash", usage, DEFAULT_PRICING, y2026)).toBeCloseTo(0.03036, 6);
  });

  test("the same call costs double from 1 Jan 2027 ($1.50 / $7.50)", () => {
    const y2027 = Date.parse("2027-01-01T00:00:00Z");
    expect(estimateCostUsd("gemini-3.6-flash", usage, DEFAULT_PRICING, y2027)).toBeCloseTo(0.06072, 6);
  });

  test("Flash-Lite is cheaper and has no 2027 change", () => {
    const a = estimateCostUsd("gemini-3.5-flash-lite", usage, DEFAULT_PRICING, y2026);
    const b = estimateCostUsd("gemini-3.5-flash-lite", usage, DEFAULT_PRICING, Date.parse("2027-06-01T00:00:00Z"));
    expect(a).toBeCloseTo((7480 * 0.3 + 6600 * 2.5) / 1e6, 8);
    expect(a).toBe(b);
  });

  test("an unknown model has no invented price — null", () => {
    expect(estimateCostUsd("gemini-99", usage, DEFAULT_PRICING, y2026)).toBeNull();
  });
});

describe("privacy", () => {
  test("the user is stored only as a stable one-way hash", () => {
    const uid = "Zk3pQ9vR2mXaLd8YbN4tUcHe7Sw1";
    const h = hashUid(uid);
    expect(h).toMatch(/^[0-9a-f]{32}$/);
    expect(h).toBe(hashUid(uid));
    expect(h).not.toContain(uid);
    expect(hashUid("someone-else")).not.toBe(h);
  });
});

describe("buildUsageRecord", () => {
  test("carries every field the cost dashboard needs, with a hashed user and a computed cost", () => {
    const rec = buildUsageRecord({
      fn: "concise", engine: "concise", model: "gemini-3.6-flash", pages: 4, questionCount: 32, attempt: 2, ok: true,
      finishReason: "STOP", usage: { promptTokens: 1000, outputTokens: 500, thinkingTokens: 200, imageTokens: 400, totalTokens: 1700 },
      uid: "user-1", requestId: "req-1", nowMs: Date.parse("2026-09-19T00:00:00Z"), pricing: DEFAULT_PRICING,
    });
    expect(rec).toMatchObject({ fn: "concise", engine: "concise", pages: 4, questionCount: 32, attempt: 2, ok: true, finishReason: "STOP", thinkingTokens: 200, imageTokens: 400, requestId: "req-1" });
    expect(rec.costUsd).toBeCloseTo((1000 * 0.75 + 700 * 3.75) / 1e6, 8);
    expect(rec.uidHash).not.toContain("user-1");
    expect(JSON.stringify(rec)).not.toContain("user-1");
  });
});
