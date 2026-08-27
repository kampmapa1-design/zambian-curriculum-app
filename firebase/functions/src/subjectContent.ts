// ---------------------------------------------------------------------
// Extracts usable teaching text from a downloaded CDC Teaching Module PDF,
// for storage in the app's on-device Subject Content Database (see
// SubjectContentRepository in the Flutter app) — investigated against a
// real sample (2026-08-27, civic_education_module.pdf) rather than
// guessed: unlike scanned past papers, Teaching Modules are genuine
// digital-text PDFs, so plain text extraction (pdf-parse, built on
// pdf.js) works well with no OCR needed.
//
// Every module opens with several pages of front matter — Vision,
// Authors, Coordinators, Typesetter, Preface, Acknowledgement — that name
// real people. Per this project's sourcing rule (real people's names
// never surface in generated app content), extraction always cuts
// everything before the module's own "Introduction" heading, so only the
// actual curriculum content (numbered topics/sub-topics, from "1.8 RISK
// MANAGEMENT" onward in the sample) is ever stored or used.
// ---------------------------------------------------------------------

// eslint-disable-next-line @typescript-eslint/no-var-requires
const pdfParse = require("pdf-parse");

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

/** Collapses the excess blank lines pdf-parse tends to leave behind. */
function tidyWhitespace(text: string): string {
  return text
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export async function extractSubjectContentText(pdfBytes: Buffer): Promise<string> {
  const data = await pdfParse(pdfBytes);
  const withoutFrontMatter = stripFrontMatter(data.text as string);
  return tidyWhitespace(withoutFrontMatter);
}
