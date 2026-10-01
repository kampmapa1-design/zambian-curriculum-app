import type { GoogleGenAI } from "@google/genai";
import { buildFeatureRecords, generateTracked, newUsageContext, runWithUsage } from "./aiUsage";
import { DEFAULT_PRICING } from "./usageLog";

const response = (prompt: number, out: number, thoughts: number) => ({
  text: "hello",
  candidates: [{ finishReason: "STOP" }],
  usageMetadata: { promptTokenCount: prompt, candidatesTokenCount: out, thoughtsTokenCount: thoughts, promptTokensDetails: [{ modality: "IMAGE", tokenCount: 400 }] },
});
const fakeAi = (responses: unknown[]) => {
  let i = 0;
  return { models: { generateContent: async () => responses[i++] } } as unknown as GoogleGenAI;
};
const NOW = Date.parse("2026-09-19T00:00:00Z");

describe("generateTracked", () => {
  test("returns the model's response untouched, and records its usage in the current scope", async () => {
    const ctx = newUsageContext("lessonPlan", "uid-1", "req-1");
    const r = await runWithUsage(ctx, () => generateTracked(fakeAi([response(1000, 500, 200)]), { model: "gemini-3.6-flash", contents: "x" }));
    expect(r.text).toBe("hello");
    expect(ctx.calls).toHaveLength(1);
    expect(ctx.calls[0]).toMatchObject({ model: "gemini-3.6-flash", finishReason: "STOP", usage: { promptTokens: 1000, outputTokens: 500, thinkingTokens: 200, imageTokens: 400 } });
  });

  test("outside any scope (e.g. inside the marking functions) it is a plain pass-through and records nothing", async () => {
    const r = await generateTracked(fakeAi([response(1, 1, 0)]), { model: "gemini-3.6-flash", contents: "x" });
    expect(r.text).toBe("hello");
  });

  test("concurrent requests keep their usage separate", async () => {
    const a = newUsageContext("lessonPlan", "a");
    const b = newUsageContext("transcription", "b");
    await Promise.all([
      runWithUsage(a, async () => {
        await new Promise((r) => setTimeout(r, 10));
        await generateTracked(fakeAi([response(10, 10, 0)]), { model: "m", contents: "x" });
      }),
      runWithUsage(b, async () => {
        await generateTracked(fakeAi([response(20, 20, 0)]), { model: "m", contents: "x" });
        await generateTracked(fakeAi([response(30, 30, 0)]), { model: "m", contents: "x" });
      }),
    ]);
    expect(a.calls).toHaveLength(1);
    expect(b.calls).toHaveLength(2);
  });

  test("a failed Gemini call propagates and records nothing", async () => {
    const ctx = newUsageContext("lessonPlan", "u");
    const bad = {
      models: {
        generateContent: async () => {
          throw new Error("429");
        },
      },
    } as unknown as GoogleGenAI;
    await expect(runWithUsage(ctx, () => generateTracked(bad, { model: "m", contents: "x" }))).rejects.toThrow("429");
    expect(ctx.calls).toHaveLength(0);
  });
});

describe("buildFeatureRecords", () => {
  const usage = (p: number, o: number) => ({ promptTokens: p, outputTokens: o, thinkingTokens: 0, imageTokens: 0, totalTokens: p + o });

  test("costs every call at the model's price; only the LAST call of a successful request is marked ok", () => {
    const ctx = newUsageContext("requiredCoreTopics", "uid-1", "req-1");
    ctx.calls.push(
      { model: "gemini-3.6-flash", usage: usage(1000, 500), finishReason: "STOP" },
      { model: "gemini-3.6-flash", usage: usage(2000, 1000), finishReason: "STOP" }
    );
    const recs = buildFeatureRecords(ctx, true, NOW, DEFAULT_PRICING);
    expect(recs.map((r) => r.ok)).toEqual([false, true]);
    expect(recs[0].costUsd).toBeCloseTo((1000 * 0.75 + 500 * 3.75) / 1e6, 8);
    expect(recs[1].costUsd).toBeCloseTo((2000 * 0.75 + 1000 * 3.75) / 1e6, 8);
    expect(recs.every((r) => r.feature === "requiredCoreTopics" && r.requestId === "req-1")).toBe(true);
  });

  test("a failed request marks nothing ok, and an unpriced model is null — never a fake zero", () => {
    const ctx = newUsageContext("x", "u");
    ctx.calls.push({ model: "gemini-99", usage: usage(1, 1), finishReason: null });
    const [r] = buildFeatureRecords(ctx, false, NOW, DEFAULT_PRICING);
    expect(r.ok).toBe(false);
    expect(r.costUsd).toBeNull();
  });

  test("the user appears only as a one-way hash", () => {
    const ctx = newUsageContext("x", "secret-uid-123");
    ctx.calls.push({ model: "m", usage: usage(1, 1), finishReason: null });
    expect(JSON.stringify(buildFeatureRecords(ctx, true, NOW, DEFAULT_PRICING))).not.toContain("secret-uid-123");
  });
});
