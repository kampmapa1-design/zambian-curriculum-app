import { onCall, onRequest, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { GoogleGenAI } from "@google/genai";
import { stripKnownWatermarks } from "./watermark";
import { extractSubjectContentText } from "./subjectContent";

// Stopgap while the Anthropic account is blocked on identity verification
// (started 2026-08-26). ALL THREE functions below now run on a free Gemini
// API key (no card required, from aistudio.google.com/apikey) via
// `firebase functions:secrets:set GEMINI_API_KEY`, instead of Anthropic.
// As of 2026-08-27, listCdcResources also moved to Gemini (it originally
// needed Anthropic's web_search/web_fetch tools — see the preserved
// original implementation and revert notes right above the current
// listCdcResources export below).
//
// TO REVERT EVERYTHING BACK TO ANTHROPIC once verification is resolved:
// 1. `npm install` in this folder (package.json still lists
//    @anthropic-ai/sdk — it was never removed, just unused meanwhile).
// 2. Restore `import Anthropic from "@anthropic-ai/sdk";` above and
//    `const anthropicApiKey = defineSecret("ANTHROPIC_API_KEY");` here.
// 3. generateTeachingNotes / generateSlideOutline: change `secrets:
//    [geminiApiKey]` back to `[anthropicApiKey]`, and swap each function's
//    Gemini `ai.models.generateContent(...)` call block back to an
//    Anthropic `client.messages.create(...)` call (buildPrompt/
//    buildSlidePrompt are shared and don't need to change).
// 4. listCdcResources: delete the current Gemini-based body and restore
//    the "ORIGINAL ANTHROPIC IMPLEMENTATION" block preserved in a comment
//    directly above it.
// 5. `firebase functions:secrets:set ANTHROPIC_API_KEY` with a real key,
//    then `firebase deploy --only functions`.
const geminiApiKey = defineSecret("GEMINI_API_KEY");
// gemini-2.5-flash returned a 404 in production (2026-08-27) — Google's own
// error said it's "no longer available to new users" (this API key is
// freshly created) and pointed to this model instead. Bump this constant
// again if it's ever deprecated the same way.
const GEMINI_MODEL = "gemini-3.6-flash";

type NotesFormat = "bullet" | "paragraph";

interface GenerateTeachingNotesRequest {
  topic: string;
  subtopic?: string;
  syllabusContext: string;
  format: NotesFormat;
}

interface GenerateTeachingNotesResponse {
  notes: string;
  topic: string;
  subtopic: string | null;
  format: NotesFormat;
}

function buildPrompt(req: GenerateTeachingNotesRequest): string {
  const formatInstruction =
    req.format === "bullet"
      ? "Format the notes as clearly organized bullet points, grouped under short subheadings."
      : "Format the notes as flowing prose paragraphs, organized under short subheadings.";

  const lengthInstruction =
    req.format === "paragraph"
      ? "Write teaching notes for a teacher preparing a lesson, no more than 700 words in total."
      : "Write teaching notes for a teacher preparing a lesson. Bullet points are already " +
        "condensed, so there is no word-count target — cover the topic thoroughly rather than " +
        "padding or trimming to hit a length.";

  return [
    lengthInstruction,
    `Topic: ${req.topic}`,
    req.subtopic ? `Sub-topic: ${req.subtopic}` : null,
    "",
    "Syllabus context — ground every claim in this and do not introduce content outside its scope:",
    req.syllabusContext,
    "",
    formatInstruction,
    "Draw only on well-established, credible educational knowledge appropriate for this " +
      "syllabus context. Do not fabricate facts, statistics, or sources. If the syllabus " +
      "context is too thin to responsibly cover the topic, say so explicitly rather than " +
      "inventing content.",
    "Write only the teaching notes themselves — no preamble, no meta-commentary about the " +
      "word count or format.",
    "Write in plain text only — no Markdown formatting of any kind (no #, ##, ###, **, *, __, " +
      "---, or backticks). This is a professional document a teacher will export and print, " +
      "not a chat reply, so it must never carry visible markup syntax.",
  ]
    .filter((line): line is string => line !== null)
    .join("\n");
}

export const generateTeachingNotes = onCall<GenerateTeachingNotesRequest>(
  // maxInstances caps concurrent execution — a safety net against a bug or
  // burst of calls running up spend faster than a budget alert would catch
  // it. Low on purpose for a prototype under real testing.
  { secrets: [geminiApiKey], region: "us-central1", maxInstances: 5 },
  async (request): Promise<GenerateTeachingNotesResponse> => {
    // Callable functions verify the Firebase Auth ID token automatically —
    // request.auth is only populated for requests carrying a valid token
    // from THIS Firebase project, which is what keeps arbitrary callers off
    // the function (and off the API budget behind it).
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in is required to generate teaching notes."
      );
    }

    const { topic, subtopic, syllabusContext, format } = request.data ?? {};

    if (typeof topic !== "string" || topic.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'topic' is required.");
    }
    if (typeof syllabusContext !== "string" || syllabusContext.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'syllabusContext' is required.");
    }
    if (format !== "bullet" && format !== "paragraph") {
      throw new HttpsError("invalid-argument", "'format' must be 'bullet' or 'paragraph'.");
    }
    if (subtopic !== undefined && typeof subtopic !== "string") {
      throw new HttpsError("invalid-argument", "'subtopic' must be a string if provided.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const req: GenerateTeachingNotesRequest = { topic, subtopic, syllabusContext, format };

    let text: string | undefined;
    try {
      // Flash, not Pro: this is a per-user, potentially-frequent call (every
      // "Try AI-enhanced version" tap), and the task — condensing syllabus
      // context into formatted notes — is well within its strengths. Also
      // the free-tier-eligible model, which matters while this is running
      // on a card-free Google AI Studio key rather than a funded account.
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: buildPrompt(req),
      });
      text = response.text;
    } catch (err) {
      console.error("Gemini API call failed", err);
      throw new HttpsError("internal", "Failed to generate teaching notes. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any text.");
    }

    return {
      notes: text,
      topic,
      subtopic: subtopic ?? null,
      format,
    };
  }
);

// ---------------------------------------------------------------------
// listCdcResources — catalogs teaching modules published on the Curriculum
// Development Centre's digital library (library.cdcrepository.info), so the
// app can show teachers what's available without bundling every PDF (the
// full catalog runs into hundreds of megabytes — see firebase/README.md for
// why on-demand download + a periodic catalog refresh was chosen instead of
// embedding everything).
// ---------------------------------------------------------------------

interface CdcResource {
  title: string;
  subjectName: string | null;
  level: string | null;
  term: string | null;
  url: string;
  resourceType: "module" | "syllabus" | "past_paper";
}

interface ListCdcResourcesResponse {
  resources: CdcResource[];
  fetchedAt: string;
}

const nullableString = { anyOf: [{ type: "string" }, { type: "null" }] };

const cdcResourcesSchema = {
  type: "object",
  properties: {
    resources: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          subjectName: nullableString,
          level: nullableString,
          term: nullableString,
          url: { type: "string" },
          resourceType: { type: "string", enum: ["module", "syllabus", "past_paper"] },
        },
        required: ["title", "url", "subjectName", "level", "term", "resourceType"],
        additionalProperties: false,
      },
    },
  },
  required: ["resources"],
  additionalProperties: false,
};

const CDC_CATALOG_PROMPT = [
  "Catalog three kinds of downloadable Zambian secondary-school resources so a " +
    "teacher-facing app can list them for download. Tag every resource you record with a " +
    "resourceType of exactly 'module', 'syllabus', or 'past_paper' as described below.",
  "",
  "1) CDC Teaching Modules (resourceType: 'module') — search and browse " +
    "https://library.cdcrepository.info/ (its browse.php?level=ece, ?level=primary, and " +
    "?level=secondary listing pages, and their pagination) to find as many individual " +
    "Teaching Module resources as you reasonably can within your tool-call budget.",
  "",
  "2) CDC secondary-school syllabi (resourceType: 'syllabus') — browse " +
    "https://library.cdcrepository.info/browse.php?level=syllabi&grade=syl_olevel (the " +
    "O-Level/secondary syllabus listing, and its pagination) to find official CDC syllabus " +
    "documents.",
  "",
  "3) ECZ (Examinations Council of Zambia) Grade 12 secondary-school-leaving past exam " +
    "papers (resourceType: 'past_paper') — the ECZ site itself (www.exams-council.org.zm) " +
    "does not publish past papers for free download, so search and browse reliable " +
    "open-access compilations instead: https://www.zambiapapers.com/grade-12 (subject pages " +
    "like /grade-12/biology-paper-1) and https://www.zedpastpapers.com/ . Each subject/paper " +
    "page typically lists one entry per exam year — record EACH YEAR as its own separate " +
    "resource, with the year included in the title (e.g. 'Biology Paper 1 (2019)'), not one " +
    "merged entry per subject. ONLY record papers from 2017 onwards — never 2016 or earlier. " +
    "ONLY record Grade 12 papers — Grade 9 has been phased out by ECZ and must never be " +
    "included, even if a source site still lists Grade 9 pages (e.g. ignore " +
    "zambiapapers.com/grade-9 entirely). Only record papers with a genuine, working link — " +
    "skip anything broken, paywalled, or requiring an account.",
  "",
  "IMPORTANT for past papers specifically: these sites usually link out to a Google Drive " +
    "'preview' page (a URL like https://drive.google.com/file/d/FILE_ID/preview or " +
    ".../view) rather than a direct file. When you find one, convert it to a direct-download " +
    "URL before recording it: https://drive.google.com/uc?export=download&id=FILE_ID (using " +
    "the same FILE_ID). Only record the converted direct-download form, never the raw " +
    "preview/view URL.",
  "",
  "For each resource of any type, record: the exact title as listed (past papers: include " +
    "the exam year in the title as above), the subject name, the grade/level/form it's for, " +
    "the term if stated (null if not applicable, e.g. for a syllabus or past paper), and the " +
    "direct resource/download URL.",
  "",
  "Prioritize breadth (covering many subjects across all three categories) over " +
    "exhaustively listing every single resource on any one site — this catalog will be " +
    "refreshed periodically, so a good partial pass across all three categories now is " +
    "better than exhausting your budget on just one.",
  "",
  "Only include resources you actually found on these sites. Do not invent titles, " +
    "subjects, or URLs. If a category's sites are unreachable, skip that category rather " +
    "than guessing — return whatever you could genuinely verify from the others.",
].join("\n");

// ---------------------------------------------------------------------
// ORIGINAL ANTHROPIC IMPLEMENTATION — preserved here verbatim (2026-08-27)
// so reverting is a copy-paste, not a rewrite. To restore: follow the
// numbered steps in the top-of-file comment, then replace the live
// `listCdcResources` export below with this block (uncommented, and with
// `Record<string, never>` etc. restored as needed):
//
// export const listCdcResources = onCall<Record<string, never>>(
//   // Left on claude-opus-5 (unlike the two Haiku functions below): this one
//   // is throttled client-side to at most once a week per device
//   // (CdcResourcesService in the Flutter app), and its job — multi-step web
//   // browsing plus structured extraction — benefits more from a stronger
//   // model than the per-request cost matters here. maxInstances caps
//   // concurrent runs regardless.
//   { secrets: [anthropicApiKey], region: "us-central1", timeoutSeconds: 480, memory: "512MiB", maxInstances: 3 },
//   async (request): Promise<ListCdcResourcesResponse> => {
//     // Same auth gate as generateTeachingNotes — this still spends API
//     // budget (web search/fetch + generation), so only signed-in app clients
//     // may call it.
//     if (!request.auth) {
//       throw new HttpsError("unauthenticated", "Sign in is required to fetch CDC resources.");
//     }
//
//     const client = new Anthropic({ apiKey: anthropicApiKey.value() });
//
//     const tools: Anthropic.Messages.ToolUnion[] = [
//       { type: "web_search_20260318", name: "web_search", max_uses: 30 },
//       {
//         type: "web_fetch_20260318",
//         name: "web_fetch",
//         max_uses: 40,
//         allowed_domains: ["library.cdcrepository.info", "www.zambiapapers.com", "www.zedpastpapers.com"],
//       },
//     ];
//     const outputConfig = { format: { type: "json_schema" as const, schema: cdcResourcesSchema } };
//
//     let messages: Anthropic.Messages.MessageParam[] = [{ role: "user", content: CDC_CATALOG_PROMPT }];
//     let response;
//     let resumes = 0;
//
//     try {
//       response = await client.messages.create({
//         model: "claude-opus-5",
//         max_tokens: 8000,
//         tools,
//         output_config: outputConfig,
//         messages,
//       });
//
//       // Server-side tool loops (web_search/web_fetch) can hit their default
//       // iteration cap mid-crawl; resend to resume rather than returning a
//       // truncated catalog. Capped so one call can't run away.
//       while (response.stop_reason === "pause_turn" && resumes < 3) {
//         messages = [
//           { role: "user", content: CDC_CATALOG_PROMPT },
//           { role: "assistant", content: response.content },
//         ];
//         response = await client.messages.create({
//           model: "claude-opus-5",
//           max_tokens: 8000,
//           tools,
//           output_config: outputConfig,
//           messages,
//         });
//         resumes += 1;
//       }
//     } catch (err) {
//       console.error("CDC catalog fetch failed", err);
//       throw new HttpsError("internal", "Failed to fetch the CDC catalog. Please try again.");
//     }
//
//     if (response.stop_reason === "refusal") {
//       throw new HttpsError("failed-precondition", "The catalog request was declined.");
//     }
//
//     const textBlock = response.content.find(
//       (block): block is Anthropic.TextBlock => block.type === "text"
//     );
//     if (!textBlock) {
//       throw new HttpsError("internal", "No catalog data was returned.");
//     }
//
//     let parsed: { resources?: CdcResource[] };
//     try {
//       parsed = JSON.parse(textBlock.text);
//     } catch (err) {
//       console.error("CDC catalog response was not valid JSON", textBlock.text);
//       throw new HttpsError("internal", "The catalog response could not be parsed.");
//     }
//
//     return {
//       resources: parsed.resources ?? [],
//       fetchedAt: new Date().toISOString(),
//     };
//   }
// );
// ---------------------------------------------------------------------

export const listCdcResources = onCall<Record<string, never>>(
  // Gemini stopgap (2026-08-27, see top-of-file comment). Two calls instead
  // of Anthropic's one: Gemini's proven generateContent endpoint (the same
  // one the other two functions already use successfully) doesn't reliably
  // combine browsing tools with strict JSON schema output in a single call,
  // so 1) a research call with googleSearch+urlContext tools grounds real
  // findings from the target sites as free text, then 2) a tool-free
  // second call reshapes that text into cdcResourcesSchema. Both steps use
  // GEMINI_MODEL (Flash) rather than a "pro" model — this fresh API key
  // already lost access to gemini-2.5-flash days after creation (see
  // GEMINI_MODEL comment above), so a preview-tier pro model felt too
  // likely to hit the same wall; revisit if research quality is thin.
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 480, memory: "512MiB", maxInstances: 3 },
  async (request): Promise<ListCdcResourcesResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to fetch CDC resources.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

    let researchText: string | undefined;
    try {
      const researchResponse = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: CDC_CATALOG_PROMPT,
        config: {
          tools: [{ urlContext: {} }, { googleSearch: {} }],
        },
      });
      researchText = researchResponse.text;
    } catch (err) {
      console.error("Gemini CDC research call failed", err);
      throw new HttpsError("internal", "Failed to fetch the CDC catalog. Please try again.");
    }

    if (!researchText) {
      throw new HttpsError("internal", "No catalog data was returned.");
    }

    let text: string | undefined;
    try {
      const structureResponse = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [
          "Extract the resources described in the research notes below into the given JSON " +
            "schema. Only include resources actually described in the notes — do not invent " +
            "titles, subjects, or URLs. If the notes describe no resources, return an empty " +
            "resources array.",
          "",
          "Research notes:",
          researchText,
        ].join("\n"),
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: cdcResourcesSchema,
        },
      });
      text = structureResponse.text;
    } catch (err) {
      console.error("Gemini CDC structuring call failed", err);
      throw new HttpsError("internal", "Failed to fetch the CDC catalog. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "No catalog data was returned.");
    }

    let parsed: { resources?: CdcResource[] };
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("CDC catalog response was not valid JSON", text);
      throw new HttpsError("internal", "The catalog response could not be parsed.");
    }

    return {
      resources: parsed.resources ?? [],
      fetchedAt: new Date().toISOString(),
    };
  }
);

// ---------------------------------------------------------------------
// generateSlideOutline — condenses already-generated teaching notes into a
// ~15-slide deck outline (intro, ~60% of the main points, conclusion). The
// Flutter app's OfflineSlideOutlineService always produces a usable outline
// first, offline; this function is the optional AI-enhanced upgrade called
// when online, matching generateTeachingNotes' pattern exactly — same auth
// gate, same Haiku model, same graceful-fallback contract with the client.
// ---------------------------------------------------------------------

type NotesFormatForSlides = "bullet" | "paragraph";

interface GenerateSlideOutlineRequest {
  topic: string;
  subtopic?: string;
  notesText: string;
  notesFormat: NotesFormatForSlides;
}

interface SlideOutlineSlide {
  title: string;
  bullets: string[];
}

interface GenerateSlideOutlineResponse {
  deckTitle: string;
  slides: SlideOutlineSlide[];
}

const slideOutlineSchema = {
  type: "object",
  properties: {
    deckTitle: { type: "string" },
    slides: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          bullets: { type: "array", items: { type: "string" } },
        },
        required: ["title", "bullets"],
        additionalProperties: false,
      },
    },
  },
  required: ["deckTitle", "slides"],
  additionalProperties: false,
};

function buildSlidePrompt(req: GenerateSlideOutlineRequest): string {
  return [
    "Condense the following teaching notes into a PowerPoint slide deck outline for a teacher " +
      "to present in class.",
    `Topic: ${req.topic}`,
    req.subtopic ? `Sub-topic: ${req.subtopic}` : null,
    "",
    "Teaching notes to condense — ground every slide in this content, do not introduce facts " +
      "outside it:",
    req.notesText,
    "",
    "Produce a slide deck: a title slide, a short introduction slide, the main points condensed " +
      "to roughly 60% of the notes' original detail — prioritize breadth of coverage over " +
      "exhaustive depth on any one point — and a short conclusion slide. Every content slide " +
      "(introduction, main points, and conclusion alike) must have AT LEAST 4 bullet points and " +
      "no more than 6, short phrases not full sentences. Never create a slide with fewer than 4 " +
      "bullets — if there isn't enough content left for a full slide, merge it into the previous " +
      "slide or drop it rather than publish a thin slide. This means the deck should have fewer " +
      "slides overall when the notes are short, and more when they are long — aim for roughly " +
      "15 slides only when the notes comfortably support that many at 4-6 bullets each.",
    "IMPORTANT — introduction and conclusion slides must be about the topic's actual subject " +
      "matter, never about learning objectives or outcomes: the introduction slide dives " +
      "straight into the topic itself (what it is, its key context, why it matters) exactly " +
      "like the first main-points slide would, just framed as an opening; the conclusion slide " +
      "summarizes the actual content covered across the deck (the main facts, ideas, or " +
      "processes taught), not a restatement of what learners 'should now be able to do'. Never " +
      "write a slide titled or framed around 'Objectives', 'Learning Objectives', or similar — " +
      "if the notes above include objectives/competencies language, treat that as background, " +
      "not slide content.",
    "Do not fabricate content beyond what's in the notes above. Write only the slide outline — " +
      "no preamble or meta-commentary.",
    "Write in plain text only — no Markdown formatting of any kind (no #, ##, ###, **, *, __, " +
      "---, or backticks) anywhere in the deck title, slide titles, or bullets.",
  ]
    .filter((line): line is string => line !== null)
    .join("\n");
}

export const generateSlideOutline = onCall<GenerateSlideOutlineRequest>(
  { secrets: [geminiApiKey], region: "us-central1", maxInstances: 5 },
  async (request): Promise<GenerateSlideOutlineResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to generate slides.");
    }

    const { topic, subtopic, notesText, notesFormat } = request.data ?? {};

    if (typeof topic !== "string" || topic.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'topic' is required.");
    }
    if (typeof notesText !== "string" || notesText.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'notesText' is required.");
    }
    if (notesFormat !== "bullet" && notesFormat !== "paragraph") {
      throw new HttpsError("invalid-argument", "'notesFormat' must be 'bullet' or 'paragraph'.");
    }
    if (subtopic !== undefined && typeof subtopic !== "string") {
      throw new HttpsError("invalid-argument", "'subtopic' must be a string if provided.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const req: GenerateSlideOutlineRequest = { topic, subtopic, notesText, notesFormat };

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: buildSlidePrompt(req),
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: slideOutlineSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("Gemini API call failed", err);
      throw new HttpsError("internal", "Failed to generate slide outline. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any slides.");
    }

    let parsed: GenerateSlideOutlineResponse;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("Slide outline response was not valid JSON", text);
      throw new HttpsError("internal", "The slide outline response could not be parsed.");
    }

    return parsed;
  }
);

// ---------------------------------------------------------------------
// cleanPastPaperDownload — fetches a past-paper PDF from its source URL
// (Google Drive, see CdcResourcesService in the Flutter app) and strips
// known redistributor watermarks (zedpastpapers.com, zambiapapers.com,
// etc.) before the app ever saves it — see watermark.ts for exactly how
// and why that's safe to do (real content is never touched; a file with
// no matching watermark comes back byte-for-byte unchanged). Runs
// server-side rather than in the app because pdf-lib's content-stream
// surgery needs Node — there's no equivalent Dart library for editing an
// existing PDF's internal structure.
// ---------------------------------------------------------------------

interface CleanPastPaperDownloadRequest {
  url: string;
}

interface CleanPastPaperDownloadResponse {
  base64: string;
}

export const cleanPastPaperDownload = onCall<CleanPastPaperDownloadRequest>(
  { region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<CleanPastPaperDownloadResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to download this file.");
    }

    const { url } = request.data ?? {};
    if (typeof url !== "string" || url.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'url' is required.");
    }

    let fetched: Response;
    try {
      fetched = await fetch(url, {
        headers: {
          "User-Agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/128.0.0.0 Safari/537.36",
        },
      });
    } catch (err) {
      console.error("cleanPastPaperDownload: fetch failed", err);
      throw new HttpsError("unavailable", "Could not reach the file's source. Please try again.");
    }
    if (!fetched.ok) {
      throw new HttpsError("unavailable", `Download failed (HTTP ${fetched.status}).`);
    }

    const rawBytes = Buffer.from(await fetched.arrayBuffer());
    if (rawBytes.length < 5 || rawBytes.subarray(0, 5).toString("latin1") !== "%PDF-") {
      throw new HttpsError(
        "unavailable",
        "This file couldn't be downloaded right now — the source may be rate-limiting downloads. " +
          "Please try again in a few minutes.",
      );
    }

    let cleaned: Buffer;
    try {
      cleaned = await stripKnownWatermarks(rawBytes);
    } catch (err) {
      // A cleaning failure shouldn't block the download entirely — the
      // teacher still gets the real (possibly watermarked) paper rather
      // than nothing.
      console.error("cleanPastPaperDownload: watermark stripping failed, returning original", err);
      cleaned = rawBytes;
    }

    return { base64: cleaned.toString("base64") };
  }
);

// ---------------------------------------------------------------------
// extractSubjectContentText — pulls usable teaching text out of a
// downloaded Teaching Module PDF (or similar "Subject Content Material"),
// for the Flutter app's on-device Subject Content Database
// (SubjectContentRepository) to store in place of the much bulkier raw
// PDF. Runs server-side because pdfjs-dist (Mozilla's real PDF.js) is a
// mature, proven text-extraction path with no Dart equivalent — see
// subjectContent.ts for exactly how, and why real people's names from a
// module's front matter never end up in what's stored. The app sends the
// raw bytes it already has on-device (not a URL) since this covers both
// a fresh CDC download and a teacher-supplied file the same way.
// ---------------------------------------------------------------------

interface ExtractSubjectContentTextRequest {
  base64: string;
}

interface ExtractSubjectContentTextResponse {
  text: string;
}

export const extractSubjectContentTextFn = onCall<ExtractSubjectContentTextRequest>(
  { region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<ExtractSubjectContentTextResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to process this file.");
    }

    const { base64 } = request.data ?? {};
    if (typeof base64 !== "string" || base64.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'base64' is required.");
    }

    let bytes: Buffer;
    try {
      bytes = Buffer.from(base64, "base64");
    } catch (err) {
      throw new HttpsError("invalid-argument", "'base64' was not valid base64 data.");
    }
    if (bytes.length < 5 || bytes.subarray(0, 5).toString("latin1") !== "%PDF-") {
      throw new HttpsError("invalid-argument", "Only PDF files are supported.");
    }

    try {
      const text = await extractSubjectContentText(bytes);
      return { text };
    } catch (err) {
      console.error("extractSubjectContentText failed", err);
      throw new HttpsError("internal", "Could not extract text from this file.");
    }
  }
);

// ---------------------------------------------------------------------
// gradeMarkingScript — AI-Assisted Marking, Stage 4. Sends one student
// script's captured page images, together with its linked marking
// scheme, to Gemini for transcription and grading. Structured JSON out:
// one graded answer per scheme question, each with a confidence value —
// Stage 5 (client-side) categorizes by that confidence, Stage 6 requires
// a teacher to review every answer before anything is final. This
// function only produces a first-pass suggestion, never a final mark.
//
// "Dual-provider" per the original spec: this app doesn't actually have a
// live, switchable dual-provider abstraction right now (see the top-of-
// file comment — everything is on Gemini while Anthropic is blocked on
// identity verification). This function is written Gemini-only for that
// same reason, isolated behind this one function so swapping/adding a
// second provider later doesn't touch the app's calling code.
// ---------------------------------------------------------------------

interface GradeMarkingScriptQuestion {
  label: string;
  expectedAnswerOrKeywords: string;
  maxMarks: number;
}

interface GradeMarkingScriptRequest {
  pageImagesBase64: string[];
  questions: GradeMarkingScriptQuestion[];
}

interface GradedAnswerResult {
  questionLabel: string;
  transcribedAnswer: string;
  marksAwarded: number;
  confidence: "high" | "medium" | "low";
}

interface GradeMarkingScriptResponse {
  answers: GradedAnswerResult[];
  observations: string[];
}

const gradeMarkingScriptSchema = {
  type: "object",
  properties: {
    answers: {
      type: "array",
      items: {
        type: "object",
        properties: {
          questionLabel: { type: "string" },
          transcribedAnswer: { type: "string" },
          marksAwarded: { type: "number" },
          confidence: { type: "string", enum: ["high", "medium", "low"] },
        },
        required: ["questionLabel", "transcribedAnswer", "marksAwarded", "confidence"],
        additionalProperties: false,
      },
    },
    // 3-5 short, specific observations about this candidate's performance
    // on THIS script, grounded in what the marking scheme actually asked
    // for — not generic praise/criticism. See buildGradingPrompt for the
    // exact instruction.
    observations: {
      type: "array",
      items: { type: "string" },
      minItems: 3,
      maxItems: 5,
    },
  },
  required: ["answers", "observations"],
  additionalProperties: false,
};

function buildGradingPrompt(questions: GradeMarkingScriptQuestion[]): string {
  const schemeText = questions
    .map((q) => `${q.label} (max ${q.maxMarks} marks): expected answer/keywords — ${q.expectedAnswerOrKeywords}`)
    .join("\n");

  return [
    "The attached images are photos of one student's answer script, in page order. Some scripts are " +
      "entirely handwritten; others mix pre-printed material (typed/printed question text, multiple-choice " +
      "options, answer-blank labels) with the student's own handwritten answers filled into blanks, margins, " +
      "or circled/ticked options. Distinguish the two: pre-printed question text is never the student's " +
      "answer, even if it's the only text near a question — look specifically for what the student " +
      "themselves wrote, marked, circled, or ticked by hand. If a question's blank was left genuinely " +
      "empty (nothing handwritten there at all), that's a missing answer, not something to infer from the " +
      "printed question text.",
    "Your job:",
    "1. Find each question's answer — in the student's own handwriting, or their handwritten mark/circle/" +
      "tick on a printed option — matching questions by number/label the same way as in the marking scheme " +
      "below (e.g. 'Q1', '1.', '1)' — match by number/order, not exact formatting).",
    "2. Transcribe that answer as accurately as you can (for a circled/ticked printed option, transcribe " +
      "which option was selected). If handwriting is illegible or the answer is missing entirely, say so " +
      "plainly in transcribedAnswer (e.g. 'illegible' or 'no answer found') rather than guessing at words " +
      "that aren't really there.",
    "3. Compare the transcribed answer against the expected answer/keywords and award marks out of that " +
      "question's maximum — partial credit is expected and normal, not just full marks or zero.",
    "4. Give a confidence level for EACH answer: 'high' only when both the handwriting was clearly " +
      "legible AND you're confident the mark awarded is correct; 'low' whenever either the handwriting " +
      "was hard to read, the answer was ambiguous, or you're unsure the mark is right; 'medium' " +
      "otherwise. Confidence reflects your own uncertainty honestly — it is what determines whether a " +
      "teacher is required to double-check this specific answer, so do not default to 'high'.",
    "5. Separately, write 3 to 5 short observations about this candidate's performance on THIS script — " +
      "specific strengths and/or weaknesses grounded in what the marking scheme actually asked for (e.g. " +
      "'Consistently applied the correct formula but made arithmetic slips in Q2 and Q4' or 'Strong on " +
      "definitions (Q1, Q3) but answers to application questions were too brief to earn full marks'), not " +
      "generic praise or criticism that could apply to any script. Base these only on what you actually " +
      "observed while grading, never on assumptions about the candidate.",
    "",
    "Marking scheme:",
    schemeText,
    "",
    "Return exactly one answer per question in the marking scheme, using the same question label, plus " +
      "the 3-5 observations. Every mark you award must be a first-pass suggestion for a teacher to review, " +
      "never a final grade — never fabricate an answer that isn't genuinely visible in the images.",
  ].join("\n");
}

export const gradeMarkingScript = onCall<GradeMarkingScriptRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 180, memory: "1GiB", maxInstances: 5 },
  async (request): Promise<GradeMarkingScriptResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to grade a script.");
    }

    const { pageImagesBase64, questions } = request.data ?? {};
    if (!Array.isArray(pageImagesBase64) || pageImagesBase64.length === 0) {
      throw new HttpsError("invalid-argument", "'pageImagesBase64' must be a non-empty array.");
    }
    if (!Array.isArray(questions) || questions.length === 0) {
      throw new HttpsError("invalid-argument", "'questions' must be a non-empty array.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

    const imageParts = pageImagesBase64.map((b64) => ({
      inlineData: { mimeType: "image/jpeg", data: b64 },
    }));

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: buildGradingPrompt(questions) }, ...imageParts] }],
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: gradeMarkingScriptSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("gradeMarkingScript: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to grade this script. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any grading results.");
    }

    let parsed: GradeMarkingScriptResponse;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("gradeMarkingScript: response was not valid JSON", text);
      throw new HttpsError("internal", "The grading response could not be parsed.");
    }

    return parsed;
  }
);

// ---------------------------------------------------------------------
// deriveMarkingKeyFromQuestionPaper — AI-Assisted Marking, Stage B (marking
// key generation). Unlike syllabus extraction, a question paper does NOT
// contain its own answer key — the AI has to actually answer each
// question from its own subject knowledge, not just reformat what's on
// the page. That's a materially different (and riskier) kind of AI
// output than everything else in this file, so this function's result is
// ALWAYS routed into the same editable MarkingSchemeBuilderScreen a
// teacher would use for manual entry — pre-filled, never auto-saved,
// exactly like editing any other scheme. See burst path in
// marking_scheme_list_screen.dart.
// ---------------------------------------------------------------------

interface DeriveMarkingKeyRequest {
  questionPaperText: string;
}

interface DerivedQuestion {
  label: string;
  expectedAnswerOrKeywords: string;
  maxMarks: number;
}

interface DeriveMarkingKeyResponse {
  questions: DerivedQuestion[];
  notes: string;
}

const deriveMarkingKeySchema = {
  type: "object",
  properties: {
    questions: {
      type: "array",
      items: {
        type: "object",
        properties: {
          label: { type: "string" },
          expectedAnswerOrKeywords: { type: "string" },
          maxMarks: { type: "number" },
        },
        required: ["label", "expectedAnswerOrKeywords", "maxMarks"],
        additionalProperties: false,
      },
    },
    notes: {
      type: "string",
      description:
        "Anything a teacher should double-check before trusting this key - a mark allocation the paper " +
        "didn't actually state (so one was assumed), a question whose correct answer is genuinely " +
        "debatable or curriculum-dependent, ambiguous numbering, etc. Empty string if nothing stood out.",
    },
  },
  required: ["questions", "notes"],
  additionalProperties: false,
};

function buildDeriveMarkingKeyPrompt(questionPaperText: string): string {
  return [
    "The following is the extracted text of an exam/test question paper. For EACH question on it:",
    "1. Use the paper's own question label/number (e.g. 'Q1', '1.', '1a)').",
    "2. Write a concise, accurate model answer or a comma-separated list of key points a correct answer " +
      "should include, drawing on your own subject knowledge - the paper itself does not contain the " +
      "answers, so this is you actually answering the question, not transcribing something already there. " +
      "Be precise and correct; if a question is genuinely ambiguous or you are not confident of the " +
      "correct answer, say so plainly in that question's expectedAnswerOrKeywords AND mention it in notes, " +
      "rather than stating an uncertain answer as if it were settled.",
    "3. Use the mark allocation the paper itself states for that question (e.g. '[5]', '(10 marks)') " +
      "whenever it's shown. If no mark allocation is shown for a question, make a reasonable estimate " +
      "based on the question's apparent complexity/length relative to others on the paper, and say in " +
      "notes which questions got an assumed rather than stated allocation.",
    "4. Skip pure instructions/rubric text ('Answer ALL questions in Section A', page headers, etc.) - " +
      "only real, answerable questions belong in the result.",
    "",
    "--- QUESTION PAPER TEXT ---",
    questionPaperText,
  ].join("\n");
}

export const deriveMarkingKeyFromQuestionPaper = onCall<DeriveMarkingKeyRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<DeriveMarkingKeyResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to generate a marking key.");
    }

    const { questionPaperText } = request.data ?? {};
    if (typeof questionPaperText !== "string" || questionPaperText.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'questionPaperText' is required.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: buildDeriveMarkingKeyPrompt(questionPaperText),
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: deriveMarkingKeySchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("deriveMarkingKeyFromQuestionPaper: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to generate a marking key. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return a marking key.");
    }

    let parsed: DeriveMarkingKeyResponse;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("deriveMarkingKeyFromQuestionPaper: response was not valid JSON", text);
      throw new HttpsError("internal", "The marking key response could not be parsed.");
    }

    return parsed;
  }
);

// ---------------------------------------------------------------------
// detectCandidateName — AI-Assisted Marking, Stage D. Reads the captured
// script's first page for a handwritten (or printed) candidate name, so
// the capture form can be pre-filled instead of typed from scratch. Pure
// convenience, never authoritative: the caller always keeps the fields
// editable, and this returns empty strings rather than guessing when no
// name is genuinely visible.
// ---------------------------------------------------------------------

interface DetectCandidateNameRequest {
  imageBase64: string;
}

interface DetectCandidateNameResponse {
  firstName: string;
  surname: string;
}

const detectCandidateNameSchema = {
  type: "object",
  properties: {
    firstName: { type: "string" },
    surname: { type: "string" },
  },
  required: ["firstName", "surname"],
  additionalProperties: false,
};

export const detectCandidateName = onCall<DetectCandidateNameRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 60, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<DetectCandidateNameResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to use name detection.");
    }

    const { imageBase64 } = request.data ?? {};
    if (typeof imageBase64 !== "string" || imageBase64.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'imageBase64' is required.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const prompt = [
      "This is a photo of one page of a student's answer script. Look for the candidate's name - " +
        "handwritten in a name field, header, or cover area, or printed on a pre-labeled form.",
      "Return firstName and surname separately. If you genuinely cannot find a name on this page (wrong " +
        "page, illegible, or simply not present), return empty strings for both - never guess or invent a " +
        "plausible-looking name.",
    ].join("\n");

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: prompt }, { inlineData: { mimeType: "image/jpeg", data: imageBase64 } }] }],
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: detectCandidateNameSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("detectCandidateName: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to detect a name from this page.");
    }

    if (!text) {
      return { firstName: "", surname: "" };
    }

    try {
      return JSON.parse(text) as DetectCandidateNameResponse;
    } catch (err) {
      console.error("detectCandidateName: response was not valid JSON", text);
      return { firstName: "", surname: "" };
    }
  }
);

// ---------------------------------------------------------------------
// internalBatchSyllabusExtract — TEMPORARY, one-off use only. Same
// purpose as the batch extraction function used for the original
// 18-subject CBC expansion: turns a Teaching Module's raw text into a
// structured syllabus outline (topics/sub-topics/competencies) via
// Gemini, for a local batch script to convert into the app's syllabus
// JSON schema. Not called from the Flutter app. Token-gated (not
// onCall/auth-gated) because it's driven by a local Node script, not
// the app. DELETE THIS FUNCTION (and run
// `firebase functions:delete internalBatchSyllabusExtract --region us-central1 --force`)
// once the current batch (Stage 2 of the CBC expansion, 2026-08) is done.
// ---------------------------------------------------------------------

const INTERNAL_BATCH_TOKEN = "3384ee250d75b2f6619317a1850d73de7d3ffb11f271060b";

const syllabusOutlineSchema = {
  type: "object",
  properties: {
    topics: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          description: { type: "string" },
          weekNumber: { type: "number" },
          learningObjectives: { type: "array", items: { type: "string" } },
          competencies: {
            type: "array",
            items: {
              type: "object",
              properties: {
                description: { type: "string" },
                category: { type: "string" },
              },
              required: ["description", "category"],
              additionalProperties: false,
            },
          },
          subTopics: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
                description: { type: "string" },
                weekNumber: { type: "number" },
                learningObjectives: { type: "array", items: { type: "string" } },
                competencies: {
                  type: "array",
                  items: {
                    type: "object",
                    properties: {
                      description: { type: "string" },
                      category: { type: "string" },
                    },
                    required: ["description", "category"],
                    additionalProperties: false,
                  },
                },
              },
              required: ["name", "description"],
              additionalProperties: false,
            },
          },
        },
        required: ["name", "description"],
        additionalProperties: false,
      },
    },
    completenessNotes: {
      type: "string",
      description:
        "Anything unclear, missing, ambiguous, or irregular about how this module presents its own " +
        "content — inconsistent numbering, a topic that seems to start mid-sequence, a section with no " +
        "explicit competences, etc. Empty string if nothing stood out.",
    },
  },
  required: ["topics", "completenessNotes"],
  additionalProperties: false,
};

function buildSyllabusExtractPrompt(moduleText: string): string {
  return [
    "The following is the raw extracted text of a CDC (Curriculum Development Centre, Zambia) Teaching " +
      "Module for one subject/form/term. Extract its topic/sub-topic outline exactly as the module itself " +
      "presents it — its own topic numbers, its own topic and sub-topic titles, its own stated learning " +
      "objectives and competencies (labelling each as 'General Competence' or 'Specific Competence' as the " +
      "module itself labels them, or your best judgement if unlabelled).",
    "Never invent content that is not genuinely present in the text below. If a topic has no sub-topics, " +
      "sub-topics may be an empty array. If something about the module's own structure is unclear, " +
      "ambiguous, or looks incomplete (e.g. it starts mid-sequence, a heading convention changes partway " +
      "through, a competences section is missing), say so plainly in completenessNotes rather than guessing " +
      "or silently smoothing it over.",
    "",
    "--- MODULE TEXT ---",
    moduleText,
  ].join("\n");
}

export const internalBatchSyllabusExtract = onRequest(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 300, memory: "1GiB" },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).send("POST only");
      return;
    }
    if (req.get("x-batch-token") !== INTERNAL_BATCH_TOKEN) {
      res.status(403).send("forbidden");
      return;
    }

    const moduleText = req.body?.moduleText;
    if (typeof moduleText !== "string" || moduleText.trim().length === 0) {
      res.status(400).send("'moduleText' is required");
      return;
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: buildSyllabusExtractPrompt(moduleText) }] }],
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: syllabusOutlineSchema,
        },
      });
      const text = response.text;
      if (!text) {
        res.status(500).send("empty response from Gemini");
        return;
      }
      res.status(200).json(JSON.parse(text));
    } catch (err) {
      console.error("internalBatchSyllabusExtract failed", err);
      res.status(500).send(String(err));
    }
  }
);
