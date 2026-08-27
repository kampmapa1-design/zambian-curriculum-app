// ---------------------------------------------------------------------
// Extracts usable teaching text from a downloaded CDC Teaching Module PDF,
// for storage in the app's on-device Subject Content Database (see
// SubjectContentRepository in the Flutter app) — investigated against a
// real sample (2026-08-27, civic_education_module.pdf) rather than
// guessed: unlike scanned past papers, Teaching Modules are genuine
// digital-text PDFs, so plain text extraction works well with no OCR
// needed.
//
// Runs on pdfjs-dist (the real, actively-maintained Mozilla PDF.js
// library) directly, not the popular `pdf-parse` wrapper — pdf-parse
// bundles a version of pdf.js from around 2018 that threw "Invalid PDF
// structure" on a second real module tested (2026-08-27,
// history_form1.pdf) that this project's own poppler pdftotext handled
// fine, i.e. a real, current PDF that an outdated parser chokes on.
//
// pdfjs-dist v4+ ships ESM-only (no CommonJS build), while this project
// compiles to CommonJS — a plain `import()` here gets down-leveled by tsc
// into a `require()` call, which throws (ERR_REQUIRE_ESM) on a .mjs file.
// The `new Function(...)` indirection below is the standard workaround:
// it hides the import from tsc's static rewriting, so Node executes a
// real native dynamic import at runtime. Verified working locally before
// use, not assumed.
//
// Every module opens with several pages of front matter — Vision,
// Authors, Coordinators, Typesetter, Preface, Acknowledgement — that name
// real people. Per this project's sourcing rule (real people's names
// never surface in generated app content), extraction always cuts
// everything before the module's own "Introduction" heading, so only the
// actual curriculum content (numbered topics/sub-topics, from "1.8 RISK
// MANAGEMENT" onward in the sample) is ever stored or used.
// ---------------------------------------------------------------------

import path from "path";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const importEsm = new Function("modulePath", "return import(modulePath)") as (modulePath: string) => Promise<any>;

let pdfjsPromise: Promise<any> | undefined;
function loadPdfjs() {
  if (!pdfjsPromise) pdfjsPromise = importEsm("pdfjs-dist/legacy/build/pdf.mjs");
  return pdfjsPromise;
}

async function extractRawText(pdfBytes: Buffer): Promise<string> {
  const pdfjs = await loadPdfjs();
  const pdfjsDistDir = path.dirname(require.resolve("pdfjs-dist/package.json"));

  const doc = await pdfjs.getDocument({
    data: new Uint8Array(pdfBytes),
    standardFontDataUrl: path.join(pdfjsDistDir, "standard_fonts") + path.sep,
    cMapUrl: path.join(pdfjsDistDir, "cmaps") + path.sep,
    cMapPacked: true,
    // No canvas/DOM available in Cloud Functions, and none needed — only
    // text is being pulled out, nothing is rendered.
    isEvalSupported: false,
  }).promise;

  const pageTexts: string[] = [];
  for (let i = 1; i <= doc.numPages; i++) {
    const page = await doc.getPage(i);
    const content = await page.getTextContent();
    // Real line breaks matter here, not just for readability — the front-
    // matter cut below depends on "Introduction" appearing as its own
    // line. pdf.js marks a text run's end-of-line via hasEOL; a run
    // without it is followed by more text on the same visual line.
    let pageText = "";
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    for (const item of content.items as any[]) {
      if (!("str" in item)) continue;
      pageText += item.str + (item.hasEOL ? "\n" : "");
    }
    pageTexts.push(pageText);
  }
  return pageTexts.join("\n\n");
}

/** Cuts everything up to and including the module's own "Introduction"
 * heading — a line containing *only* that word (front matter has it as a
 * standalone heading; a body heading like "1.9 INTRODUCTION TO
 * ENTREPRENEURSHIP" has more on the line and won't match, nor will the
 * table-of-contents entry, which has dot-leaders/a page number after it).
 * If no such line is found (a module laid out differently), returns the
 * text unchanged rather than guessing — better to keep a little front
 * matter than to accidentally discard real content. */
function stripFrontMatter(text: string): string {
  const match = text.match(/^[ \t]*introduction[ \t]*$/im);
  if (!match || match.index === undefined) return text;
  return text.slice(match.index + match[0].length).trim();
}

/** Collapses the excess blank lines/spacing that come out of a real PDF's
 * text layer (extra whitespace around line breaks, runs of blank lines). */
function tidyWhitespace(text: string): string {
  return text
    .replace(/[ \t]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export async function extractSubjectContentText(pdfBytes: Buffer): Promise<string> {
  const rawText = await extractRawText(pdfBytes);
  const withoutFrontMatter = stripFrontMatter(rawText);
  return tidyWhitespace(withoutFrontMatter);
}
