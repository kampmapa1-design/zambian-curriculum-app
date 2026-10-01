// Minutes Maker "Matters Arising" cross-check (owner request, 2026-09-28):
// two genuinely different modes, chosen by whether real previous-minutes
// images were actually supplied — never invented either way. This tests the
// pure prompt-building half; the image-ordering half (previous-minutes
// images first, new-meeting images last) is exercised by reading the real
// call site in `generateMinutes` directly, not duplicated here.
import { buildGenerateMinutesPrompt } from "./index";

describe("buildGenerateMinutesPrompt", () => {
  it("with previous minutes supplied: tells Gemini exactly how many images are the previous minutes, and to cross-check them", () => {
    const prompt = buildGenerateMinutesPrompt({ hasPreviousMinutes: true, previousMinutesPageCount: 3 });
    expect(prompt).toContain("FIRST 3 image(s)");
    expect(prompt).toContain("PREVIOUS meeting's own minutes");
    expect(prompt).toContain("Addressed, Resolved, or is still Outstanding");
    expect(prompt).not.toContain("No previous minutes were supplied");
  });

  it("without previous minutes: forbids inventing a prior matter and requires a self-contained reference in the new notes", () => {
    const prompt = buildGenerateMinutesPrompt({ hasPreviousMinutes: false, previousMinutesPageCount: 0 });
    expect(prompt).toContain("No previous minutes were supplied");
    expect(prompt).toContain("do NOT invent, assume, or guess");
    expect(prompt).not.toContain("PREVIOUS meeting's own minutes");
  });

  it("both modes still instruct the core transcribe-and-structure rule and the never-fabricate rule", () => {
    for (const opts of [
      { hasPreviousMinutes: true, previousMinutesPageCount: 2 },
      { hasPreviousMinutes: false, previousMinutesPageCount: 0 },
    ]) {
      const prompt = buildGenerateMinutesPrompt(opts);
      expect(prompt).toContain("transcribe-and-structure task");
      expect(prompt).toContain("Do not fabricate content");
    }
  });
});
