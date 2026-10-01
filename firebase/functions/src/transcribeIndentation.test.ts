// Assignment Submission main-body paragraph-indentation detection (owner
// request, 2026-09-28): a purely structural check — the generic
// Handwriting-to-Word-Document feature must never see this instruction at
// all (its own callers never set detectParagraphIndentation), so the
// default (false) prompt must stay byte-identical to before this change.
import { buildTranscribeHandwrittenDocumentPrompt } from "./index";

describe("buildTranscribeHandwrittenDocumentPrompt", () => {
  it("default (false) mode says nothing about indentation or ambiguousParagraphBreaks", () => {
    const prompt = buildTranscribeHandwrittenDocumentPrompt(false);
    expect(prompt).not.toContain("indentation");
    expect(prompt).not.toContain("ambiguousParagraphBreaks");
    expect(prompt).toContain("5. Skip page numbers");
  });

  it("indentation mode instructs auto-splitting clear signals and flagging ambiguous ones instead of guessing", () => {
    const prompt = buildTranscribeHandwrittenDocumentPrompt(true);
    expect(prompt).toContain("starts horizontally relative to the lines around it");
    expect(prompt).toContain("split the content into separate 'paragraph' blocks at that point yourself");
    expect(prompt).toContain("do NOT split it in 'blocks'");
    expect(prompt).toContain("ambiguousParagraphBreaks");
  });

  it("indentation mode still forbids touching the transcribed wording, and forbids flagging non-paragraph blocks", () => {
    const prompt = buildTranscribeHandwrittenDocumentPrompt(true);
    expect(prompt).toContain("continue transcribing the actual wording exactly as written");
    expect(prompt).toContain("Never point 'ambiguousParagraphBreaks' at a heading/subheading/bullet/numbered block");
  });

  it("both modes still carry the core never-invent transcription rules", () => {
    for (const withIndentation of [true, false]) {
      const prompt = buildTranscribeHandwrittenDocumentPrompt(withIndentation);
      expect(prompt).toContain("never inventing or paraphrasing away");
      expect(prompt).toContain("do not correct spelling/grammar, do not summarize, do not omit content");
    }
  });
});
