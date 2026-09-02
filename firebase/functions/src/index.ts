import { onCall, onRequest, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { GoogleGenAI } from "@google/genai";
import * as admin from "firebase-admin";
import { stripKnownWatermarks } from "./watermark";
import { extractSubjectContentText } from "./subjectContent";

// Initialized once at module scope, used by the Teacher Submissions
// Dashboard functions (requestDashboardAccessCode, verifyDashboardAccessCode,
// submitToTeacherDashboard, getSubmissionFileUrl - added 2026-09-02) for
// Firestore + Cloud Storage + custom-claim access, all via the Admin SDK
// (bypasses the security rules in firebase/firestore.rules and
// firebase/storage.rules by design - those rules lock clients out
// entirely so this is the only path in or out).
admin.initializeApp();

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
  // Added 2026-09-02 for Lesson Plan's companion "Lesson Notes" document -
  // "'page'" caps bullet-format notes to roughly one typed page instead of
  // the standalone Teaching Notes feature's normal "no target, be
  // thorough" behavior (see buildPrompt's use of it). Ignored for
  // 'paragraph' format, which already has its own 700-word cap.
  maxLength?: "page";
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
      : req.maxLength === "page"
        ? "Write bulletin-style notes summarizing this ENTIRE topic as a single-page reference " +
          "document - use as many concise bullet points as it takes to cover the topic " +
          "thoroughly, up to approximately one full typed page (roughly 450-600 words' worth of " +
          "bullets). Prioritize the most important points if the topic is larger than a page can " +
          "hold; do not pad with filler to reach the target, and do not run noticeably past it."
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

    const { topic, subtopic, syllabusContext, format, maxLength } = request.data ?? {};

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
    if (maxLength !== undefined && maxLength !== "page") {
      throw new HttpsError("invalid-argument", "'maxLength' must be 'page' if provided.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const req: GenerateTeachingNotesRequest = { topic, subtopic, syllabusContext, format, maxLength };

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
// generateLessonPlan — AI-enhanced upgrade for "Generate Lesson Plan",
// which is otherwise entirely offline (see lesson_progression_generator.dart
// — fixed boilerplate sentences with real syllabus competencies bulleted
// in). This fills the same fields with lesson-specific content instead,
// grounded strictly in the real syllabus context passed in (competencies,
// objectives, references) — never introducing outside content. Optional,
// same pattern as Teaching Notes' "Try AI-enhanced version": the offline
// generator remains the default, this is a request-time upgrade.
// ---------------------------------------------------------------------

interface GenerateLessonPlanRequest {
  topic: string;
  subtopic?: string;
  competencies: string[];
  objectives: string[];
  references?: string;
  progressionStages: string[];
  // Added 2026-09-02: real material already saved on this device for this
  // exact topic (an excerpt from the teacher's own downloaded/extracted
  // CDC Subject Content Database materials, or a matching real embedded
  // lesson plan) - see buildLessonPlanPrompt's use of it, and
  // lesson_plan_screen.dart's _loadSubjectContentIndex for where it comes
  // from client-side. Optional: most topics don't have anything saved yet.
  subjectContentExcerpt?: string;
}

interface LessonPlanProgressionRow {
  stage: string;
  teacherRole: string;
  learnersRole: string;
  assessmentCriteria: string;
}

interface GenerateLessonPlanResponse {
  rationale: string;
  priorKnowledge: string;
  tlm: string;
  expectedStandard: string;
  progression: LessonPlanProgressionRow[];
}

const generateLessonPlanSchema = {
  type: "object",
  properties: {
    rationale: {
      type: "string",
      description:
        "2-3 sentences: why this lesson matters and how it connects to prior learning. No Markdown.",
    },
    priorKnowledge: {
      type: "string",
      description: "1-2 sentences: what learners already know coming into this lesson. No Markdown.",
    },
    tlm: {
      type: "string",
      description:
        "A short, real, obtainable list of Teaching and Learning Materials (chalkboard, charts, " +
        "textbook pages from the references provided) — never equipment a typical Zambian classroom " +
        "would not plausibly have. Plain text, comma or newline separated, no Markdown.",
    },
    expectedStandard: {
      type: "string",
      description: "1-2 sentences: what a learner who met the outcomes below can now do. No Markdown.",
    },
    progression: {
      type: "array",
      description: "Exactly one entry per stage name given, in the same order.",
      items: {
        type: "object",
        properties: {
          stage: { type: "string", description: "Must exactly match one of the given stage names." },
          teacherRole: {
            type: "string",
            description:
              "Specific to this lesson's real content — never generic filler with no subject content in it.",
          },
          learnersRole: { type: "string" },
          assessmentCriteria: { type: "string" },
        },
        required: ["stage", "teacherRole", "learnersRole", "assessmentCriteria"],
        additionalProperties: false,
      },
    },
  },
  required: ["rationale", "priorKnowledge", "tlm", "expectedStandard", "progression"],
  additionalProperties: false,
};

function buildLessonPlanPrompt(req: GenerateLessonPlanRequest): string {
  return [
    "Write a lesson plan for a Zambian secondary-school teacher, for exactly one lesson period, " +
      "covering only the syllabus content below — do not introduce content outside its scope, and do " +
      "not pad any field to fill space.",
    "",
    `Topic: ${req.topic}`,
    req.subtopic ? `Sub-topic: ${req.subtopic}` : null,
    "",
    "Syllabus context — the lesson MUST cover every one of these and nothing else:",
    ...req.competencies.map((c) => `- ${c}`),
    ...req.objectives.map((o) => `- ${o}`),
    "",
    req.references
      ? "References available for this lesson (cite naturally where relevant, never invent a " +
        `citation not listed here):\n${req.references}`
      : null,
    "",
    req.subjectContentExcerpt
      ? "Real material already saved on this teacher's own device for this exact topic (from their " +
        "downloaded CDC materials or a real embedded lesson plan) - ground the lesson in this FIRST, " +
        "before anything else. Only bring in your own general knowledge to fill gaps this material " +
        "doesn't cover, and never contradict what's given here:\n" +
        `${req.subjectContentExcerpt}\n`
      : null,
    `Lesson stages, in order: ${req.progressionStages.join(", ")}. Produce exactly one progression ` +
      "entry per stage, in that order, with Teacher's Role, Learners' Role, and Assessment Criteria " +
      "specific to this lesson's actual content.",
    "Keep every field concise — a working document a teacher reads in the classroom, not an essay.",
    "Write in plain text only — no Markdown formatting of any kind (no #, ##, ###, **, *, __, ---, or " +
      "backticks). This is a professional document a teacher will export and print, not a chat reply.",
    "If the syllabus context above is too thin to responsibly plan a full lesson, say so explicitly " +
      "in the rationale field rather than inventing content to fill the gaps.",
  ]
    .filter((line): line is string => line !== null)
    .join("\n");
}

export const generateLessonPlan = onCall<GenerateLessonPlanRequest>(
  { secrets: [geminiApiKey], region: "us-central1", maxInstances: 5 },
  async (request): Promise<GenerateLessonPlanResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to generate a lesson plan.");
    }

    const { topic, subtopic, competencies, objectives, references, progressionStages, subjectContentExcerpt } =
      request.data ?? {};

    if (typeof topic !== "string" || topic.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'topic' is required.");
    }
    if (!Array.isArray(competencies) || !competencies.every((c) => typeof c === "string")) {
      throw new HttpsError("invalid-argument", "'competencies' must be a string array.");
    }
    if (!Array.isArray(objectives) || !objectives.every((o) => typeof o === "string")) {
      throw new HttpsError("invalid-argument", "'objectives' must be a string array.");
    }
    if (
      !Array.isArray(progressionStages) ||
      progressionStages.length === 0 ||
      !progressionStages.every((s) => typeof s === "string")
    ) {
      throw new HttpsError("invalid-argument", "'progressionStages' must be a non-empty string array.");
    }
    if (subtopic !== undefined && typeof subtopic !== "string") {
      throw new HttpsError("invalid-argument", "'subtopic' must be a string if provided.");
    }
    if (references !== undefined && typeof references !== "string") {
      throw new HttpsError("invalid-argument", "'references' must be a string if provided.");
    }
    if (subjectContentExcerpt !== undefined && typeof subjectContentExcerpt !== "string") {
      throw new HttpsError("invalid-argument", "'subjectContentExcerpt' must be a string if provided.");
    }
    if (competencies.length === 0 && objectives.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "At least one competency or objective is required — a lesson plan cannot be grounded in nothing."
      );
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const req: GenerateLessonPlanRequest = {
      topic,
      subtopic,
      competencies,
      objectives,
      references,
      progressionStages,
      subjectContentExcerpt,
    };

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: buildLessonPlanPrompt(req),
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: generateLessonPlanSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("generateLessonPlan: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to generate a lesson plan. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return a lesson plan.");
    }

    let parsed: GenerateLessonPlanResponse;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("generateLessonPlan: response was not valid JSON", text);
      throw new HttpsError("internal", "The lesson plan response could not be parsed.");
    }

    return parsed;
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

// A hint, not ground truth - see buildGradingPrompt's use of it. Comes
// from Test Submission's Stage 3 question-number detection (added
// 2026-09-02) when a script was created via that feature's "Send to
// Marking" bridge (Stage 10); absent for every ordinary captured script.
interface PreSegmentedAnswerHint {
  questionNumber: string;
  text: string;
}

interface GradeMarkingScriptRequest {
  pageImagesBase64: string[];
  questions: GradeMarkingScriptQuestion[];
  preSegmentedAnswers?: PreSegmentedAnswerHint[];
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

function buildGradingPrompt(
  questions: GradeMarkingScriptQuestion[],
  preSegmentedAnswers?: PreSegmentedAnswerHint[]
): string {
  const schemeText = questions
    .map((q) => `${q.label} (max ${q.maxMarks} marks): expected answer/keywords — ${q.expectedAnswerOrKeywords}`)
    .join("\n");

  const hintSection =
    preSegmentedAnswers && preSegmentedAnswers.length > 0
      ? [
          "",
          "A separate transcription pass already attempted to split this script's answers by detected " +
            "question-number marker, in page order. Treat this ONLY as a helpful prior, never as ground " +
            "truth: it may mislabel a segment 'Unlabeled', match the wrong question number, or split/merge " +
            "answers incorrectly. Verify every segment against the actual images and use your own judgment " +
            "- correct any mismatch silently rather than propagating it.",
          "Pre-segmented answers (questionNumber: text):",
          preSegmentedAnswers.map((s) => `${s.questionNumber}: ${s.text}`).join("\n"),
        ].join("\n")
      : "";

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
    hintSection,
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

    const { pageImagesBase64, questions, preSegmentedAnswers } = request.data ?? {};
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
        contents: [
          { role: "user", parts: [{ text: buildGradingPrompt(questions, preSegmentedAnswers) }, ...imageParts] },
        ],
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
// key generation). Two source types, two very different risk profiles:
// - "questionPaper": the paper does NOT contain its own answer key, so the
//   AI has to actually answer each question from its own subject
//   knowledge, not just reformat what's on the page.
// - "markingKey": an existing marking key/answer key DOES already contain
//   the answers - this is a read-and-structure task like the app's other
//   extraction features, not an answer-from-scratch task, and is
//   instructed accordingly (never invent, flag anything unclear).
// Either way, this function's result is ALWAYS routed into the same
// editable MarkingSchemeBuilderScreen a teacher would use for manual
// entry - pre-filled, never auto-saved. See marking_scheme_list_screen.dart.
//
// Accepts EITHER already-extracted text (questionPaperText - PDF path,
// via extractSubjectContentTextFn) OR photographed page images
// (pageImagesBase64 - camera-capture path) as the source content.
// ---------------------------------------------------------------------

type MarkingKeySourceType = "questionPaper" | "markingKey";

interface DeriveMarkingKeyRequest {
  sourceType?: MarkingKeySourceType;
  questionPaperText?: string;
  pageImagesBase64?: string[];
}

interface DerivedQuestion {
  label: string;
  expectedAnswerOrKeywords: string;
  maxMarks: number;
  sectionName: string;
}

interface DerivedSection {
  name: string;
  answerInstructions: string;
}

interface DeriveMarkingKeyResponse {
  questions: DerivedQuestion[];
  sections: DerivedSection[];
  notes: string;
  detectedTitle: string;
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
          sectionName: {
            type: "string",
            description:
              "The heading of the section this question belongs to, exactly as printed (e.g. 'Section A', " +
              "'Part II'), or an empty string if the paper has no section headings at all.",
          },
        },
        required: ["label", "expectedAnswerOrKeywords", "maxMarks", "sectionName"],
        additionalProperties: false,
      },
    },
    sections: {
      type: "array",
      description:
        "One entry per distinct section heading found on the document (same order they appear), each " +
        "paired with that section's own answer instructions - empty array if the paper has no sections.",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          answerInstructions: {
            type: "string",
            description:
              "That section's own instruction line to candidates, exactly as printed/written (e.g. " +
              "'Answer ALL questions in this section', 'Answer any THREE of the following FIVE " +
              "questions') - empty string if the section prints no such instruction of its own.",
          },
        },
        required: ["name", "answerInstructions"],
        additionalProperties: false,
      },
    },
    notes: {
      type: "string",
      description:
        "Anything a teacher should double-check before trusting this key - a mark allocation the source " +
        "didn't actually state (so one was assumed), a question whose correct answer is genuinely " +
        "debatable or curriculum-dependent, ambiguous/illegible numbering, etc. Empty string if nothing " +
        "stood out.",
    },
    detectedTitle: {
      type: "string",
      description:
        "The exam/document's own title, heading, or exam name exactly as printed or written on the page " +
        "(e.g. 'Grade 12 Mathematics Final Examination', 'BSc Semester 2 Marking Scheme') - whatever it " +
        "genuinely says at the top of the document. Empty string if no such title/heading is visible " +
        "anywhere on the document - never invent one.",
    },
  },
  required: ["questions", "sections", "notes", "detectedTitle"],
  additionalProperties: false,
};

function buildDeriveMarkingKeyPrompt(sourceType: MarkingKeySourceType, isImageSource: boolean): string {
  const sourceDescription = isImageSource
    ? "The attached images are photos of one document, in page order."
    : "The following is the extracted text of one document.";

  if (sourceType === "markingKey") {
    return [
      `${sourceDescription} It is an existing marking key / answer key for an assessment - it already ` +
        "contains the expected answers and (usually) mark allocations. Read what is actually there and " +
        "structure it - do NOT invent, improve, or second-guess an answer the key itself states, even if " +
        "you think a different answer would be more correct; this is a transcription/structuring task, " +
        "not an answering task.",
      "For EACH question on it:",
      "1. Use the key's own question label/number (e.g. 'Q1', '1.', '1a)').",
      "2. Copy the expected answer/keywords as the key itself states them (handwritten or printed) - " +
        "preserve the key's own wording rather than paraphrasing where practical.",
      "3. Use the mark allocation the key itself states for that question. If none is shown for a " +
        "question, make a reasonable estimate and say in notes which questions got an assumed allocation.",
      "4. If any part of the key is illegible or ambiguous, say so plainly in that question's " +
        "expectedAnswerOrKeywords AND in notes, rather than guessing at what it might say.",
      "5. Skip pure page headers/footers/candidate-declaration boilerplate, but do NOT skip section " +
        "headings or their own answer instructions ('Answer ALL questions in this section', 'Answer any " +
        "THREE of the following FIVE questions') - capture those via sectionName and sections below rather " +
        "than discarding them; only actual answerable questions go in the questions array itself.",
      "6. Set each question's sectionName to the heading of the section it falls under, exactly as printed " +
        "(e.g. 'Section A', 'Part II'), or an empty string if the document has no section headings at all.",
      "7. Populate sections with one entry per distinct section heading found (in the order they appear), " +
        "each paired with that section's own real answer-instruction line exactly as printed/written - " +
        "empty array if there are no sections.",
      "8. Set detectedTitle to the document's own title/heading exactly as printed or written (e.g. 'Grade " +
        "12 Mathematics Final Examination'), or an empty string if none is genuinely visible - never invent " +
        "one.",
      "",
      isImageSource ? "" : "--- MARKING KEY TEXT ---",
      isImageSource ? "" : "",
    ].join("\n");
  }

  return [
    `${sourceDescription} It is an exam/test question paper - it does NOT contain its own answers. For ` +
      "EACH question on it:",
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
    "4. Skip pure page headers/footers/candidate-declaration boilerplate, but do NOT skip section headings " +
      "or their own answer instructions ('Answer ALL questions in Section A', 'Answer any THREE of the " +
      "following FIVE questions in Section B') - capture those via sectionName and sections below rather " +
      "than discarding them; only actual answerable questions go in the questions array itself.",
    "5. Set each question's sectionName to the heading of the section it falls under, exactly as printed " +
      "(e.g. 'Section A', 'Part II'), or an empty string if the paper has no section headings at all.",
    "6. Populate sections with one entry per distinct section heading found (in the order they appear), " +
      "each paired with that section's own real answer-instruction line exactly as printed/written - empty " +
      "array if there are no sections.",
    "7. Set detectedTitle to the document's own title/heading exactly as printed or written (e.g. 'Grade " +
      "12 Mathematics Final Examination'), or an empty string if none is genuinely visible - never invent " +
      "one.",
  ].join("\n");
}

export const deriveMarkingKeyFromQuestionPaper = onCall<DeriveMarkingKeyRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<DeriveMarkingKeyResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to generate a marking key.");
    }

    const { questionPaperText, pageImagesBase64 } = request.data ?? {};
    const sourceType: MarkingKeySourceType = request.data?.sourceType === "markingKey" ? "markingKey" : "questionPaper";
    const hasText = typeof questionPaperText === "string" && questionPaperText.trim().length > 0;
    const hasImages = Array.isArray(pageImagesBase64) && pageImagesBase64.length > 0;
    if (!hasText && !hasImages) {
      throw new HttpsError("invalid-argument", "Either 'questionPaperText' or 'pageImagesBase64' is required.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const promptText = buildDeriveMarkingKeyPrompt(sourceType, hasImages);
    const contents = hasImages
      ? [
          {
            role: "user",
            parts: [
              { text: promptText },
              ...pageImagesBase64!.map((b64) => ({ inlineData: { mimeType: "image/jpeg", data: b64 } })),
            ],
          },
        ]
      : `${promptText}\n${questionPaperText}`;

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents,
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
// transcribeHandwrittenList — for teachers who mark scripts by hand and
// keep a running handwritten class list rather than using the app's AI
// grading pipeline at all. Photographs of that list (whatever pattern it
// uses - a table with columns, a plain name+score list, anything else)
// are transcribed GENERICALLY as a table (headers if the list has them,
// plus rows of cells) - not forced into a fixed name/score shape, so it
// reproduces whatever was actually on the page. See
// GenericListDocumentService (client) for how this becomes an actual
// editable .docx a teacher can open in Word and correct directly, rather
// than a review UI inside the app.
// ---------------------------------------------------------------------

interface TranscribeHandwrittenListRequest {
  pageImagesBase64: string[];
}

interface TranscribeHandwrittenListResponse {
  headers: string[];
  rows: string[][];
  notes: string;
}

const transcribeHandwrittenListSchema = {
  type: "object",
  properties: {
    headers: {
      type: "array",
      items: { type: "string" },
      description:
        "Column headers, in left-to-right order, exactly as they appear on the list (e.g. 'Name', " +
        "'Score', 'Gender') - empty array if the list has no header row at all.",
    },
    rows: {
      type: "array",
      items: {
        type: "array",
        items: { type: "string" },
        description: "One row's cell values, in the same left-to-right column order as headers.",
      },
      description: "One entry per array for each row on the list, top to bottom, page order.",
    },
    notes: {
      type: "string",
      description:
        "Anything a teacher should double-check - a cell whose handwriting was hard to read, a row that " +
        "looked altered/unclear, a row skipped entirely because nothing legible could be read from it. " +
        "Empty string if nothing stood out.",
    },
  },
  required: ["headers", "rows", "notes"],
  additionalProperties: false,
};

export const transcribeHandwrittenList = onCall<TranscribeHandwrittenListRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<TranscribeHandwrittenListResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to transcribe a list.");
    }

    const { pageImagesBase64 } = request.data ?? {};
    if (!Array.isArray(pageImagesBase64) || pageImagesBase64.length === 0) {
      throw new HttpsError("invalid-argument", "'pageImagesBase64' must be a non-empty array.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const prompt = [
      "The attached images are photos of a handwritten (or printed) list a teacher kept, in page order - " +
        "typically a class list of student names and marks a teacher recorded after marking scripts by " +
        "hand, but read whatever is ACTUALLY on the page, in whatever layout it genuinely uses.",
      "1. If the list has column headers (e.g. 'Name', 'Score', 'Gender', 'Remarks'), read them exactly as " +
        "written, left to right, into 'headers'. If there are no headers at all, return an empty array - " +
        "do not invent headers that aren't genuinely on the page.",
      "2. Read every data row, top to bottom in page order, into 'rows' - each row is an array of cell " +
        "values in the same left-to-right column order as the headers (or, if there were no headers, in " +
        "whatever consistent column order the list itself uses).",
      "3. Preserve the list's own structure - if it's a table with ruled columns, follow those columns " +
        "exactly. If it's a simpler list (e.g. just 'Name - Score' per line with no table), still split " +
        "each line into logical cells the same way for every row.",
      "4. If a cell is illegible or you're not confident, still include your best reading but say so " +
        "plainly in notes (which row, what's uncertain) rather than silently guessing without flagging " +
        "it. Never invent a row that isn't genuinely on the list.",
      "5. Skip page headers/titles that aren't actually a column-header row, and skip anything that isn't " +
        "genuinely an entry on the list.",
    ].join("\n");

    const imageParts = pageImagesBase64.map((b64) => ({
      inlineData: { mimeType: "image/jpeg", data: b64 },
    }));

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: prompt }, ...imageParts] }],
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: transcribeHandwrittenListSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("transcribeHandwrittenList: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to transcribe this list. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any transcribed rows.");
    }

    try {
      return JSON.parse(text) as TranscribeHandwrittenListResponse;
    } catch (err) {
      console.error("transcribeHandwrittenList: response was not valid JSON", text);
      throw new HttpsError("internal", "The transcription response could not be parsed.");
    }
  }
);

// ---------------------------------------------------------------------
// transcribeHandwrittenDocument — "Handwriting to Word Document
// Conversion". Unlike transcribeHandwrittenList (a table of rows), this
// is for free-form handwritten notes/documents of any shape — a letter,
// a set of notes, an essay, anything with real paragraph/heading/list
// structure rather than rows and columns. Returns a sequence of typed
// blocks (heading/paragraph/bullet/numbered) in reading order, which the
// client renders into an actual editable .docx.
// ---------------------------------------------------------------------

interface TranscribeHandwrittenDocumentRequest {
  pageImagesBase64: string[];
}

type DocumentBlockType = "heading" | "subheading" | "paragraph" | "bullet" | "numbered";

interface DocumentBlock {
  type: DocumentBlockType;
  text: string;
}

interface TranscribeHandwrittenDocumentResponse {
  title: string;
  blocks: DocumentBlock[];
  notes: string;
}

const transcribeHandwrittenDocumentSchema = {
  type: "object",
  properties: {
    title: {
      type: "string",
      description:
        "A short title for the document - the page's own heading/title if it has one, otherwise a brief " +
        "descriptive title based on the content. Never leave empty.",
    },
    blocks: {
      type: "array",
      items: {
        type: "object",
        properties: {
          type: {
            type: "string",
            enum: ["heading", "subheading", "paragraph", "bullet", "numbered"],
            description:
              "'heading' for a main section title, 'subheading' for a smaller section title, 'paragraph' for " +
              "normal prose, 'bullet' for one unordered list item, 'numbered' for one ordered list item.",
          },
          text: { type: "string", description: "The block's text content, exactly as written." },
        },
        required: ["type", "text"],
        additionalProperties: false,
      },
      description: "The document's content, in reading order (top to bottom, page by page).",
    },
    notes: {
      type: "string",
      description:
        "Anything a reader should double-check - a word or passage that was hard to read, a section that " +
        "looked cut off or unclear. Empty string if nothing stood out.",
    },
  },
  required: ["title", "blocks", "notes"],
  additionalProperties: false,
};

export const transcribeHandwrittenDocument = onCall<TranscribeHandwrittenDocumentRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<TranscribeHandwrittenDocumentResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to transcribe a document.");
    }

    const { pageImagesBase64 } = request.data ?? {};
    if (!Array.isArray(pageImagesBase64) || pageImagesBase64.length === 0) {
      throw new HttpsError("invalid-argument", "'pageImagesBase64' must be a non-empty array.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const prompt = [
      "The attached images are photos of handwritten (or printed) page(s) of a document, in page order - " +
        "notes, a letter, an essay, a set of instructions, anything. Read everything genuinely written on " +
        "the page(s) and reproduce it faithfully as structured content, never inventing or paraphrasing away " +
        "what's actually there.",
      "1. Give the document a short 'title' - use the page's own heading/title if it has one, otherwise a " +
        "brief descriptive title.",
      "2. Break the content into 'blocks' in reading order: 'heading' for a main section title, 'subheading' " +
        "for a smaller section title, 'paragraph' for ordinary prose (keep a paragraph as one block even if " +
        "it wraps several lines), 'bullet' for each unordered list item as its own block, 'numbered' for " +
        "each ordered list item as its own block.",
      "3. Preserve the actual wording exactly as written, including spelling as the writer wrote it - do not " +
        "correct spelling/grammar, do not summarize, do not omit content.",
      "4. If a word or passage is illegible or you're not confident, still include your best reading but say " +
        "so plainly in notes (which section, what's uncertain) rather than silently guessing without " +
        "flagging it.",
      "5. Skip page numbers, margin scribbles, and anything that isn't genuinely part of the document's own " +
        "content.",
    ].join("\n");

    const imageParts = pageImagesBase64.map((b64) => ({
      inlineData: { mimeType: "image/jpeg", data: b64 },
    }));

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: prompt }, ...imageParts] }],
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: transcribeHandwrittenDocumentSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("transcribeHandwrittenDocument: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to transcribe this document. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any transcribed content.");
    }

    try {
      return JSON.parse(text) as TranscribeHandwrittenDocumentResponse;
    } catch (err) {
      console.error("transcribeHandwrittenDocument: response was not valid JSON", text);
      throw new HttpsError("internal", "The transcription response could not be parsed.");
    }
  }
);

// ---------------------------------------------------------------------
// extractCoverPageFields — Assignment Submission, Stage 1. Reads a photo
// of a student's handwritten cover page and pulls out the standard
// fields (student name, ID, course, subject, title, teacher, date,
// institution) into a structured, editable form — pure convenience, the
// same "never authoritative, always editable" principle as the now-
// suspended detectCandidateName below. Never invents a value: a field
// genuinely not visible on the page comes back as an empty string, not a
// guess.
// ---------------------------------------------------------------------

interface ExtractCoverPageFieldsRequest {
  imageBase64: string;
}

interface ExtractCoverPageFieldsResponse {
  studentName: string;
  idNumber: string;
  course: string;
  subject: string;
  assignmentTitle: string;
  teacherName: string;
  date: string;
  institution: string;
  notes: string;
}

const extractCoverPageFieldsSchema = {
  type: "object",
  properties: {
    studentName: { type: "string", description: "The student's name as written. Empty string if not present." },
    idNumber: { type: "string", description: "Student ID / registration number, as written. Empty if absent." },
    course: { type: "string", description: "Course name, as written. Empty if absent." },
    subject: { type: "string", description: "Subject name, as written. Empty if absent." },
    assignmentTitle: { type: "string", description: "The assignment's title, as written. Empty if absent." },
    teacherName: { type: "string", description: "Lecturer/teacher name, as written. Empty if absent." },
    date: { type: "string", description: "The date exactly as written on the page. Empty if absent." },
    institution: { type: "string", description: "Institution/school name, as written. Empty if absent." },
    notes: {
      type: "string",
      description:
        "Anything a student should double-check - a field that was hard to read or ambiguous. Empty string " +
        "if nothing stood out.",
    },
  },
  required: [
    "studentName", "idNumber", "course", "subject", "assignmentTitle", "teacherName", "date", "institution", "notes",
  ],
  additionalProperties: false,
};

export const extractCoverPageFields = onCall<ExtractCoverPageFieldsRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 60, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<ExtractCoverPageFieldsResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to read a cover page.");
    }
    const { imageBase64 } = request.data ?? {};
    if (typeof imageBase64 !== "string" || imageBase64.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'imageBase64' is required.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const prompt = [
      "The attached image is a photo of a student's handwritten assignment cover page. Read exactly what is " +
        "written and extract these standard fields: Student Name, ID/Registration Number, Course, Subject, " +
        "Assignment Title, Lecturer/Teacher Name, Date, Institution.",
      "For each field: if it is genuinely written on the page, transcribe it exactly (do not correct spelling, " +
        "do not reformat). If a field is not present on the page at all, return an empty string for it - never " +
        "invent or guess a value.",
      "If any field's handwriting was hard to read, still give your best reading but say so in notes.",
    ].join("\n");

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: prompt }, { inlineData: { mimeType: "image/jpeg", data: imageBase64 } }] }],
        config: { responseMimeType: "application/json", responseJsonSchema: extractCoverPageFieldsSchema },
      });
      text = response.text;
    } catch (err) {
      console.error("extractCoverPageFields: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to read the cover page. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any content.");
    }
    try {
      return JSON.parse(text) as ExtractCoverPageFieldsResponse;
    } catch (err) {
      console.error("extractCoverPageFields: response was not valid JSON", text);
      throw new HttpsError("internal", "The cover page response could not be parsed.");
    }
  }
);

// ---------------------------------------------------------------------
// transcribeReferencePage — Assignment Submission, Stage 4. Like
// transcribeHandwrittenDocument, but for a reference/bibliography page
// specifically: one entry per reference, with particular care for the
// exact formatting a real reference list carries (hanging indentation,
// italics, punctuation) — never correcting or completing a citation the
// student wrote incorrectly or incompletely, since that's the student's
// own academic work to get right, not this app's to fix for them.
// ---------------------------------------------------------------------

interface TranscribeReferencePageRequest {
  pageImagesBase64: string[];
  referenceSystem: string;
}

interface TranscribeReferencePageResponse {
  entries: string[];
  notes: string;
}

const transcribeReferencePageSchema = {
  type: "object",
  properties: {
    entries: {
      type: "array",
      items: { type: "string" },
      description:
        "One string per reference/bibliography entry, in the order written, formatting (indentation as " +
        "leading spaces, italics marked with *asterisks*, punctuation) preserved exactly as written.",
    },
    notes: {
      type: "string",
      description:
        "Anything a student should double-check - an entry that was hard to read, or one whose formatting " +
        "doesn't match the stated reference system (described, not corrected). Empty string if nothing stood out.",
    },
  },
  required: ["entries", "notes"],
  additionalProperties: false,
};

export const transcribeReferencePage = onCall<TranscribeReferencePageRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<TranscribeReferencePageResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to transcribe a reference page.");
    }
    const { pageImagesBase64, referenceSystem } = request.data ?? {};
    if (!Array.isArray(pageImagesBase64) || pageImagesBase64.length === 0) {
      throw new HttpsError("invalid-argument", "'pageImagesBase64' must be a non-empty array.");
    }
    if (typeof referenceSystem !== "string" || referenceSystem.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'referenceSystem' is required.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const prompt = [
      `The attached image(s) are photo(s) of a student's handwritten (or printed) reference/bibliography page, ` +
        `in page order. The student says they are using the ${referenceSystem} reference system.`,
      "Read every reference entry exactly as written and return one string per entry, in the order they " +
        "appear. Preserve the entry's own formatting as written: leading spaces for hanging indentation, wrap " +
        "italicized text (e.g. a book/journal title) in *asterisks*, keep punctuation exactly as written.",
      "Do NOT correct, complete, or reformat an entry to match the stated reference system's official rules - " +
        "reproduce faithfully what the student actually wrote, even if it deviates from the system's real " +
        "formatting rules. If an entry's formatting doesn't match what you'd expect for the stated system, " +
        "describe that in notes rather than silently fixing it.",
      "If a word or passage is illegible, still include your best reading but say so plainly in notes.",
    ].join("\n");

    const imageParts = pageImagesBase64.map((b64: string) => ({ inlineData: { mimeType: "image/jpeg", data: b64 } }));

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: prompt }, ...imageParts] }],
        config: { responseMimeType: "application/json", responseJsonSchema: transcribeReferencePageSchema },
      });
      text = response.text;
    } catch (err) {
      console.error("transcribeReferencePage: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to transcribe the reference page. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any transcribed content.");
    }
    try {
      return JSON.parse(text) as TranscribeReferencePageResponse;
    } catch (err) {
      console.error("transcribeReferencePage: response was not valid JSON", text);
      throw new HttpsError("internal", "The reference page response could not be parsed.");
    }
  }
);

// ---------------------------------------------------------------------
// sendAssignmentSubmissionEmail — Assignment Submission, Stage 8 (real
// automatic sending, added 2026-09-01; Resend -> Brevo the same day ->
// briefly back to Resend 2026-09-01 -> settled on Brevo for good
// 2026-09-02). Shared verbatim with Test Submission (see that feature's
// Stage 7 spec: "reuse Assignment Submission's transmission logic
// exactly") via the optional `submissionKind` field — still named for
// Assignment Submission since that's what it was built for first, but
// genuinely generic now, including a generic `attachments` array (not
// pdf+bundle specifically) so either feature can send however many
// files it needs. Sends via Brevo (brevo.com) - a third-party
// transactional email API, completely unrelated to Gemini/Anthropic/
// Firebase. This is genuinely automatic: unlike the WhatsApp path in
// the app (which still needs one manual tap to send via the OS share
// sheet, since no WhatsApp sending API is wired in), the student taps
// "Send" once and this function does the rest with no further
// interaction required.
//
// Settled on Brevo, not Resend, for a real, log-confirmed reason: with
// no verified custom domain, Resend's shared `onboarding@resend.dev`
// address can ONLY send to the Resend account owner's own email address
// - it 403s on any other recipient ("You can only send testing emails
// to your own email address... verify a domain... to send to other
// recipients" - the exact error a real teacher's address hit in
// production, 2026-09-01). Brevo's single-sender verification (one
// click-to-confirm email, no DNS) has no such "only yourself" ceiling
// once verified - BREVO_SENDER_EMAIL must be that verified address.
// ---------------------------------------------------------------------

const brevoApiKey = defineSecret("BREVO_API_KEY");
const brevoSenderEmail = defineSecret("BREVO_SENDER_EMAIL");

// Brevo's own limit is higher, but Cloud Functions v2 (Cloud Run
// underneath) caps request bodies well below that, and base64 inflates
// the real file size by ~33%. Stay well under both: cap the decoded
// (real) combined attachment size at 20MB.
const MAX_EMAIL_ATTACHMENT_BYTES = 20 * 1024 * 1024;

function base64DecodedByteLength(b64: string): number {
  const cleaned = b64.replace(/=+$/, "");
  return Math.floor((cleaned.length * 3) / 4);
}

interface EmailAttachment {
  filename: string;
  base64: string;
}

interface SendAssignmentSubmissionEmailRequest {
  recipientEmail: string;
  studentName: string;
  assignmentTitle: string;
  submissionHash: string;
  submittedAt: string;
  attachments: EmailAttachment[];
  submissionKind?: string;
}

interface SendAssignmentSubmissionEmailResponse {
  success: boolean;
  messageId: string;
}

export const sendAssignmentSubmissionEmail = onCall<SendAssignmentSubmissionEmailRequest>(
  {
    secrets: [brevoApiKey, brevoSenderEmail],
    region: "us-central1",
    timeoutSeconds: 180,
    memory: "512MiB",
    maxInstances: 5,
  },
  async (request): Promise<SendAssignmentSubmissionEmailResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to send a submission by email.");
    }
    const {
      recipientEmail, studentName, assignmentTitle, submissionHash, submittedAt, attachments: rawAttachments,
      submissionKind,
    } = request.data ?? {};
    const kind = typeof submissionKind === "string" && submissionKind.trim() ? submissionKind.trim() : "assignment";

    if (typeof recipientEmail !== "string" || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipientEmail.trim())) {
      throw new HttpsError("invalid-argument", "A valid recipient email address is required.");
    }
    if (!Array.isArray(rawAttachments) || rawAttachments.length === 0) {
      throw new HttpsError("invalid-argument", "At least one attachment is required.");
    }

    let totalBytes = 0;
    const attachments: { name: string; content: string }[] = [];
    for (const a of rawAttachments) {
      if (!a || typeof a.filename !== "string" || typeof a.base64 !== "string" || a.base64.length === 0) {
        throw new HttpsError("invalid-argument", "Each attachment needs a 'filename' and 'base64'.");
      }
      totalBytes += base64DecodedByteLength(a.base64);
      attachments.push({ name: a.filename, content: a.base64 });
    }
    if (totalBytes > MAX_EMAIL_ATTACHMENT_BYTES) {
      throw new HttpsError(
        "invalid-argument",
        "The submission is too large to email (over 20MB combined). Use the WhatsApp share option instead, " +
          "or reduce the number of captured pages."
      );
    }

    const safeStudentName = typeof studentName === "string" && studentName.trim() ? studentName.trim() : "A student";
    const safeTitle = typeof assignmentTitle === "string" && assignmentTitle.trim()
      ? assignmentTitle.trim() : "Untitled assignment";
    const safeHash = typeof submissionHash === "string" ? submissionHash : "";
    const safeSubmittedAt = typeof submittedAt === "string" ? submittedAt : new Date().toISOString();

    const html = [
      `<p>${safeStudentName} has submitted a${kind === "assignment" ? "n" : ""} ${kind} via Smart Teacher.</p>`,
      `<p><strong>${kind === "test" ? "Test" : "Assignment"}:</strong> ${safeTitle}</p>`,
      `<p><strong>Submitted at:</strong> ${safeSubmittedAt}</p>`,
      safeHash ? `<p><strong>Proof-of-submission hash (SHA-256):</strong> ${safeHash}</p>` : "",
      `<p>${attachments.length > 1 ? "Attached: the consolidated document, plus the original captured " +
        "pages as a viewable backup." : "The consolidated document is attached."}</p>`,
    ].join("\n");

    let response: Response;
    try {
      response = await fetch("https://api.brevo.com/v3/smtp/email", {
        method: "POST",
        headers: {
          "api-key": brevoApiKey.value(),
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: JSON.stringify({
          sender: { name: "Smart Teacher", email: brevoSenderEmail.value() },
          to: [{ email: recipientEmail.trim() }],
          subject: `${kind === "test" ? "Test" : "Assignment"} submission: ${safeTitle} - ${safeStudentName}`,
          htmlContent: html,
          attachment: attachments,
        }),
      });
    } catch (err) {
      console.error("sendAssignmentSubmissionEmail: network error calling Brevo", err);
      throw new HttpsError("unavailable", "Could not reach the email service. Please try again.");
    }

    if (!response.ok) {
      const bodyText = await response.text().catch(() => "");
      console.error("sendAssignmentSubmissionEmail: Brevo returned an error", response.status, bodyText);
      throw new HttpsError("internal", "The email service rejected the submission. Please try again.");
    }

    let messageId = "";
    try {
      const json = (await response.json()) as { messageId?: string };
      messageId = json.messageId ?? "";
    } catch {
      // Brevo responded 2xx but the body wasn't parseable JSON - not fatal, the email still sent.
    }

    return { success: true, messageId };
  }
);

// ---------------------------------------------------------------------
// transcribeTestSubmission — Test Submission, Stage 3 (added 2026-09-02).
// Reads 1-5 photographed pages of a handwritten test and structures the
// transcription by detected question number - looking for markers like
// "Question 1", "Q1", "1." at the start of each answer block. Same
// "never correct or invent" discipline as every other transcription
// function in this app: a segment with no clear marker is tagged
// "Unlabeled" rather than guessed, and content itself is transcribed
// verbatim, never corrected or completed.
// ---------------------------------------------------------------------

interface TranscribeTestSubmissionRequest {
  pageImagesBase64: string[];
}

interface TestAnswerSegmentResult {
  questionNumber: string;
  text: string;
}

interface TranscribeTestSubmissionResponse {
  segments: TestAnswerSegmentResult[];
  notes: string;
}

const transcribeTestSubmissionSchema = {
  type: "object",
  properties: {
    segments: {
      type: "array",
      items: {
        type: "object",
        properties: {
          questionNumber: {
            type: "string",
            description:
              "The detected question-number marker exactly as written (e.g. 'Question 1', 'Q1', '1.'), " +
              "normalized only to strip surrounding whitespace/punctuation - or the literal string " +
              "'Unlabeled' if no clear marker starts this answer block.",
          },
          text: { type: "string", description: "The answer text for this segment, transcribed verbatim." },
        },
        required: ["questionNumber", "text"],
        additionalProperties: false,
      },
    },
    notes: {
      type: "string",
      description: "Anything a student should double-check - illegible text, an ambiguous marker. Empty if none.",
    },
  },
  required: ["segments", "notes"],
  additionalProperties: false,
};

export const transcribeTestSubmission = onCall<TranscribeTestSubmissionRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<TranscribeTestSubmissionResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to transcribe a test submission.");
    }
    const { pageImagesBase64 } = request.data ?? {};
    if (!Array.isArray(pageImagesBase64) || pageImagesBase64.length === 0) {
      throw new HttpsError("invalid-argument", "'pageImagesBase64' must be a non-empty array.");
    }
    if (pageImagesBase64.length > 5) {
      throw new HttpsError("invalid-argument", "A test submission is capped at 5 pages.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const prompt = [
      "The attached images are photos of a student's handwritten test answers, in page order. Split the " +
        "content into segments, one per detected answer block, in the order they appear across the pages.",
      "For each segment: look at its very start for a handwritten question-number marker - things like " +
        "'Question 1', 'Q1', '1.', '1)', or similar. If you find one, use it (verbatim, just trimmed of " +
        "surrounding whitespace/punctuation) as questionNumber. If a segment genuinely has no clear marker " +
        "at its start, set questionNumber to exactly 'Unlabeled' - do not guess which question it might " +
        "belong to from context.",
      "Transcribe each segment's answer text exactly as written - preserve the student's own wording, " +
        "structure, and any in-text working/calculations. Never correct, complete, or improve what the " +
        "student wrote. If a passage is illegible, include your best reading but say so in notes.",
      "Do not merge separate answer blocks into one segment just because they share the same question " +
        "number, and do not split one continuous answer into multiple segments - one segment per answer " +
        "block, in the order it was physically written.",
    ].join("\n");

    const imageParts = pageImagesBase64.map((b64: string) => ({ inlineData: { mimeType: "image/jpeg", data: b64 } }));

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: prompt }, ...imageParts] }],
        config: { responseMimeType: "application/json", responseJsonSchema: transcribeTestSubmissionSchema },
      });
      text = response.text;
    } catch (err) {
      console.error("transcribeTestSubmission: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to transcribe this test submission. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any transcribed content.");
    }
    try {
      return JSON.parse(text) as TranscribeTestSubmissionResponse;
    } catch (err) {
      console.error("transcribeTestSubmission: response was not valid JSON", text);
      throw new HttpsError("internal", "The transcription response could not be parsed.");
    }
  }
);

// ---------------------------------------------------------------------
// Teacher Submissions Dashboard (Stage 11, added 2026-09-02) — the
// "lightweight cloud mailbox" model, chosen explicitly over a full
// accounts+rosters system: a submission is filed under the teacher's own
// email address (already collected at Stage 8 transmission), with no
// new account system, no class rosters, and no pre-created "assignment"
// entities. Four functions:
//   1. requestDashboardAccessCode - emails a one-time 6-digit code.
//   2. verifyDashboardAccessCode  - checks it, stamps a `teacherEmail`
//      custom claim on the caller's own Firebase Auth token. This is the
//      ONLY way that claim is ever set - proves inbox ownership once per
//      device, not a real login (no password, no profile).
//   3. submitToTeacherDashboard   - uploads a submission's files +
//      metadata, called by the client right after Stage 8's email send
//      (only when a teacher email was actually entered - that's the join
//      key, so there's nothing to file it under otherwise).
//   4. getSubmissionFileUrl       - hands back a short-lived signed
//      download URL for one of a submission's files, re-checking the
//      caller's claim against that submission's own teacherEmail every
//      time (not just trusting whatever was true at upload time).
// See firebase/firestore.rules and firebase/storage.rules: clients never
// read or write `submissions`/`dashboardAccessCodes` documents or
// `teacher_submissions/` files directly - every access goes through one
// of these four functions.
// ---------------------------------------------------------------------

function slugifyEmail(email: string): string {
  return email.trim().toLowerCase().replace(/[^a-z0-9]/g, "_");
}

function sanitizePathSegment(input: string): string {
  const cleaned = (input || "").trim().replace(/[/\\#[\].$]+/g, "_").replace(/\s+/g, "_");
  return cleaned.length === 0 ? "unspecified" : cleaned.slice(0, 80);
}

function isValidEmail(value: unknown): value is string {
  return typeof value === "string" && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim());
}

interface RequestDashboardAccessCodeRequest {
  email: string;
}

export const requestDashboardAccessCode = onCall<RequestDashboardAccessCodeRequest>(
  { secrets: [brevoApiKey, brevoSenderEmail], region: "us-central1", timeoutSeconds: 30, memory: "256MiB", maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to access the Submissions Dashboard.");
    }
    const { email } = request.data ?? {};
    if (!isValidEmail(email)) {
      throw new HttpsError("invalid-argument", "A valid email address is required.");
    }
    const normalizedEmail = email.trim().toLowerCase();
    const code = Math.floor(100000 + Math.random() * 900000).toString();

    await admin.firestore().collection("dashboardAccessCodes").doc(slugifyEmail(normalizedEmail)).set({
      email: normalizedEmail,
      code,
      attempts: 0,
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 10 * 60 * 1000),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    try {
      const response = await fetch("https://api.brevo.com/v3/smtp/email", {
        method: "POST",
        headers: {
          "api-key": brevoApiKey.value(),
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: JSON.stringify({
          sender: { name: "Smart Teacher", email: brevoSenderEmail.value() },
          to: [{ email: normalizedEmail }],
          subject: "Your Smart Teacher Dashboard access code",
          htmlContent:
            `<p>Your one-time code for the Submissions Dashboard is:</p>` +
            `<p style="font-size:28px;font-weight:bold;letter-spacing:4px;">${code}</p>` +
            `<p>This code expires in 10 minutes. If you didn't request this, you can ignore this email.</p>`,
        }),
      });
      if (!response.ok) {
        const bodyText = await response.text().catch(() => "");
        console.error("requestDashboardAccessCode: Brevo returned an error", response.status, bodyText);
        throw new HttpsError("internal", "Could not send the access code. Please try again.");
      }
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      console.error("requestDashboardAccessCode: network error calling Brevo", err);
      throw new HttpsError("unavailable", "Could not reach the email service. Please try again.");
    }

    return { success: true };
  }
);

interface VerifyDashboardAccessCodeRequest {
  email: string;
  code: string;
}

export const verifyDashboardAccessCode = onCall<VerifyDashboardAccessCodeRequest>(
  { region: "us-central1", timeoutSeconds: 30, memory: "256MiB", maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to access the Submissions Dashboard.");
    }
    const { email, code } = request.data ?? {};
    if (!isValidEmail(email) || typeof code !== "string" || code.trim().length === 0) {
      throw new HttpsError("invalid-argument", "A valid email and code are required.");
    }
    const normalizedEmail = email.trim().toLowerCase();
    const docRef = admin.firestore().collection("dashboardAccessCodes").doc(slugifyEmail(normalizedEmail));
    const snap = await docRef.get();
    if (!snap.exists) {
      throw new HttpsError("failed-precondition", "No code was requested for this email, or it already expired. Request a new one.");
    }
    const data = snap.data() as { email: string; code: string; attempts: number; expiresAt: admin.firestore.Timestamp };
    if (data.expiresAt.toMillis() < Date.now()) {
      await docRef.delete();
      throw new HttpsError("failed-precondition", "That code has expired. Request a new one.");
    }
    if (data.attempts >= 5) {
      await docRef.delete();
      throw new HttpsError("failed-precondition", "Too many incorrect attempts. Request a new code.");
    }
    if (data.code !== code.trim()) {
      await docRef.update({ attempts: admin.firestore.FieldValue.increment(1) });
      throw new HttpsError("permission-denied", "That code doesn't match. Check it and try again.");
    }

    await admin.auth().setCustomUserClaims(request.auth.uid, { teacherEmail: normalizedEmail });
    await docRef.delete();
    return { success: true };
  }
);

interface SubmissionFileInput {
  filename: string;
  base64: string;
  contentType: string;
}

interface SubmitToTeacherDashboardRequest {
  teacherEmail: string;
  kind: "assignment" | "test";
  studentName: string;
  className: string;
  subjectName: string;
  title: string;
  submittedAt: string;
  sha256Hash: string;
  referenceInfo: string;
  attachments: SubmissionFileInput[];
}

const MAX_DASHBOARD_UPLOAD_BYTES = 25 * 1024 * 1024;

export const submitToTeacherDashboard = onCall<SubmitToTeacherDashboardRequest>(
  { region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<{ success: boolean; submissionId: string }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to submit to the Dashboard.");
    }
    const data = request.data ?? {};
    if (!isValidEmail(data.teacherEmail)) {
      throw new HttpsError("invalid-argument", "A valid teacher email is required.");
    }
    if (data.kind !== "assignment" && data.kind !== "test") {
      throw new HttpsError("invalid-argument", "'kind' must be 'assignment' or 'test'.");
    }
    if (!Array.isArray(data.attachments) || data.attachments.length === 0) {
      throw new HttpsError("invalid-argument", "At least one attachment is required.");
    }

    let totalBytes = 0;
    for (const a of data.attachments) {
      if (!a || typeof a.filename !== "string" || typeof a.base64 !== "string" || a.base64.length === 0) {
        throw new HttpsError("invalid-argument", "Each attachment needs a 'filename' and 'base64'.");
      }
      totalBytes += Math.floor((a.base64.replace(/=+$/, "").length * 3) / 4);
    }
    if (totalBytes > MAX_DASHBOARD_UPLOAD_BYTES) {
      throw new HttpsError("invalid-argument", "This submission is too large to upload to the Dashboard.");
    }

    const normalizedEmail = data.teacherEmail.trim().toLowerCase();
    // Stage 14 — Class > Subject > Assignment/Test Name > Student Name,
    // so a teacher's own Storage browser (if they ever look) stays
    // navigable without manual sorting, same convention the Dashboard's
    // own filters (Stage 11) read back out of the Firestore fields below.
    const basePath = [
      "teacher_submissions",
      slugifyEmail(normalizedEmail),
      sanitizePathSegment(data.className),
      sanitizePathSegment(data.subjectName),
      sanitizePathSegment(data.title),
      sanitizePathSegment(data.studentName),
    ].join("/");

    const bucket = admin.storage().bucket();
    const uploadedFiles: { filename: string; storagePath: string }[] = [];
    for (const a of data.attachments) {
      const storagePath = `${basePath}/${sanitizePathSegment(a.filename)}`;
      await bucket.file(storagePath).save(Buffer.from(a.base64, "base64"), {
        contentType: a.contentType || "application/octet-stream",
      });
      uploadedFiles.push({ filename: a.filename, storagePath });
    }

    const docRef = admin.firestore().collection("submissions").doc();
    await docRef.set({
      teacherEmail: normalizedEmail,
      kind: data.kind,
      studentName: data.studentName ?? "",
      className: data.className ?? "",
      subjectName: data.subjectName ?? "",
      title: data.title ?? "",
      submittedAt: typeof data.submittedAt === "string" ? data.submittedAt : new Date().toISOString(),
      sha256Hash: data.sha256Hash ?? "",
      referenceInfo: data.referenceInfo ?? "",
      files: uploadedFiles,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true, submissionId: docRef.id };
  }
);

interface GetSubmissionFileUrlRequest {
  submissionId: string;
  storagePath: string;
}

export const getSubmissionFileUrl = onCall<GetSubmissionFileUrlRequest>(
  { region: "us-central1", timeoutSeconds: 30, memory: "256MiB", maxInstances: 5 },
  async (request): Promise<{ url: string }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const teacherEmail = request.auth.token?.teacherEmail as string | undefined;
    if (!teacherEmail) {
      throw new HttpsError("permission-denied", "Verify your teacher email first.");
    }
    const { submissionId, storagePath } = request.data ?? {};
    if (typeof submissionId !== "string" || typeof storagePath !== "string") {
      throw new HttpsError("invalid-argument", "'submissionId' and 'storagePath' are required.");
    }

    const snap = await admin.firestore().collection("submissions").doc(submissionId).get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Submission not found.");
    }
    const subData = snap.data() as { teacherEmail: string; files: { filename: string; storagePath: string }[] };
    if (subData.teacherEmail !== teacherEmail) {
      throw new HttpsError("permission-denied", "This submission isn't addressed to your verified email.");
    }
    const fileRecord = (subData.files ?? []).find((f) => f.storagePath === storagePath);
    if (!fileRecord) {
      throw new HttpsError("not-found", "File not found on this submission.");
    }

    const [url] = await admin.storage().bucket().file(storagePath).getSignedUrl({
      action: "read",
      expires: Date.now() + 15 * 60 * 1000,
    });
    return { url };
  }
);

// ---------------------------------------------------------------------
// matchTopicSearchQuery — Topic search, Method 2 of the three topic-
// selection strategies (added 2026-09-02). The client already runs a
// free local word-overlap search across every bundled subject/grade/
// topic/sub-topic name first (see topic_search_service.dart) - this
// function is ONLY called when that comes up empty, to help a teacher
// whose wording doesn't share any words with the real syllabus text
// (e.g. a genuine synonym or a differently-phrased description).
//
// Deliberately narrow and hard to hallucinate from: Gemini is given the
// exact, real list of bundled subject/grade combinations (as plain
// strings, indexed) and asked ONLY to pick the single best-matching
// index, or none. The response is validated against that same list
// before use - an out-of-range or missing index is treated as "no
// match", never guessed at. This never asks the AI to name or invent a
// topic; once a subject/grade is identified, the client falls back to
// the same real, on-device Term→Week→Topic list every other path uses.
// ---------------------------------------------------------------------

interface MatchTopicSearchQueryRequest {
  query: string;
  subjects: string[];
}

interface MatchTopicSearchQueryResponse {
  matchedIndex: number | null;
}

const matchTopicSearchQuerySchema = {
  type: "object",
  properties: {
    matchedIndex: {
      type: ["integer", "null"],
      description: "The index (from the given list) of the single best-matching subject/grade, or null if none clearly match.",
    },
  },
  required: ["matchedIndex"],
  additionalProperties: false,
};

export const matchTopicSearchQuery = onCall<MatchTopicSearchQueryRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 30, memory: "256MiB", maxInstances: 5 },
  async (request): Promise<MatchTopicSearchQueryResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to search.");
    }
    const { query, subjects } = request.data ?? {};
    if (typeof query !== "string" || query.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'query' is required.");
    }
    if (!Array.isArray(subjects) || subjects.length === 0 || !subjects.every((s) => typeof s === "string")) {
      throw new HttpsError("invalid-argument", "'subjects' must be a non-empty array of strings.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const list = subjects.map((s, i) => `${i}: ${s}`).join("\n");
    const prompt = [
      "A teacher typed the following description of what they're teaching:",
      `"${query.trim()}"`,
      "",
      "Here is the real, exact list of bundled subject/grade combinations available in this app, one per line " +
        "as 'index: description':",
      list,
      "",
      "Which single entry, if any, most likely matches what the teacher described? Consider subject name, " +
        "curriculum, and grade/form level. Respond with that entry's index. If nothing on the list is a " +
        "plausible match, respond with null - never guess at a loose or unrelated match.",
    ].join("\n");

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: prompt }] }],
        config: { responseMimeType: "application/json", responseJsonSchema: matchTopicSearchQuerySchema },
      });
      text = response.text;
    } catch (err) {
      console.error("matchTopicSearchQuery: Gemini call failed", err);
      throw new HttpsError("internal", "Could not search right now. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return a result.");
    }
    let parsed: MatchTopicSearchQueryResponse;
    try {
      parsed = JSON.parse(text) as MatchTopicSearchQueryResponse;
    } catch (err) {
      console.error("matchTopicSearchQuery: response was not valid JSON", text);
      throw new HttpsError("internal", "The search response could not be parsed.");
    }

    // Validated here, not just trusted - an index outside the real given
    // list is treated as no match, same as if Gemini had returned null.
    const index = parsed.matchedIndex;
    if (typeof index !== "number" || !Number.isInteger(index) || index < 0 || index >= subjects.length) {
      return { matchedIndex: null };
    }
    return { matchedIndex: index };
  }
);

// ---------------------------------------------------------------------
// detectCandidateName — SUSPENDED (2026-08-30). The Flutter app no longer
// calls this function: it sent one full-resolution page image to Gemini
// per script purely to pre-fill a name field a teacher can type in a few
// seconds anyway, and turned out to be a significant, easily-avoidable
// share of this app's AI cost at real usage volume. Capture screens now
// ask for name/ID/class up front via plain manual entry instead. Left
// deployed (not deleted) in case a genuinely cheap detection path is
// worth revisiting later — costs nothing while unused.
//
// AI-Assisted Marking, Stage D (as originally built) — reads the captured
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

// ---------------------------------------------------------------------
// generateMinutes — Minutes Maker, Stage 5. Reads photographed pages of
// handwritten (or typed) meeting notes, however disordered, and
// reorganizes them into a professional minutes structure: Attendees,
// Agenda, Discussion Points, Decisions Made, Action Items. Same
// transcribe-then-structure discipline as transcribeHandwrittenList: real
// content only, flagged uncertainty rather than invented content, never a
// section fabricated wholesale when the source genuinely doesn't cover it.
// ---------------------------------------------------------------------

interface GenerateMinutesRequest {
  pageImagesBase64: string[];
}

interface MinutesSectionResult {
  heading: string;
  lines: string[];
}

interface GenerateMinutesResponse {
  meetingTitle: string;
  sections: MinutesSectionResult[];
  notes: string;
}

const generateMinutesSchema = {
  type: "object",
  properties: {
    meetingTitle: {
      type: "string",
      description:
        "A short title for these minutes - the meeting's own stated name/purpose if the notes state one, " +
        "otherwise a brief descriptive title grounded in what the notes actually cover. Never invented " +
        "beyond what the notes support.",
    },
    sections: {
      type: "array",
      items: {
        type: "object",
        properties: {
          heading: {
            type: "string",
            description:
              "One of: 'Attendees', 'Agenda', 'Discussion Points', 'Decisions Made', 'Action Items'. Only " +
              "include a section the notes actually give real content for - never include a section with " +
              "an invented or placeholder line just to complete the set.",
          },
          lines: {
            type: "array",
            items: { type: "string" },
            description:
              "One entry per line. For Action Items specifically, write each as a single line naming the " +
              "action, and append ' — Owner: <name>' and/or ', Deadline: <date>' only when the notes " +
              "genuinely state an owner/deadline for that item - never invent either.",
          },
        },
        required: ["heading", "lines"],
        additionalProperties: false,
      },
    },
    notes: {
      type: "string",
      description:
        "Anything a reader should double-check - a passage that was hard to read, content that seemed to " +
        "belong to a section but was too ambiguous to place confidently. Empty string if nothing stood out.",
    },
  },
  required: ["meetingTitle", "sections", "notes"],
  additionalProperties: false,
};

function buildGenerateMinutesPrompt(): string {
  return [
    "The attached images are photos of one set of handwritten (or partly typed) meeting notes, in page " +
      "order. The notes may be disordered, non-linear, or jump between topics - your job is to READ every " +
      "genuine point made in them, then REORGANIZE that real content into a professional minutes " +
      "structure. This is a transcribe-and-structure task, not a writing task: every fact, decision, and " +
      "action item in your output must trace back to something actually written in the notes.",
    "Sort what you read into these categories, using ONLY sections the notes genuinely support:",
    "1. Attendees - names/roles listed as present, if the notes state any.",
    "2. Agenda - topics the meeting covered, if stated or clearly inferable from the notes' own structure.",
    "3. Discussion Points - what was actually discussed on each topic, summarized faithfully, not " +
      "invented or embellished.",
    "4. Decisions Made - anything the notes record as agreed/decided/resolved.",
    "5. Action Items - concrete tasks assigned or agreed to be done, each as one line naming the action, " +
      "with owner and/or deadline appended only when the notes genuinely state them.",
    "Do not fabricate content for a category the notes don't actually cover - omit that section entirely " +
      "rather than inventing a placeholder. If a passage is illegible or its category is genuinely " +
      "ambiguous, say so in notes rather than guessing silently.",
  ].join("\n");
}

export const generateMinutes = onCall<GenerateMinutesRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 120, memory: "1GiB", maxInstances: 5 },
  async (request): Promise<GenerateMinutesResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to generate minutes.");
    }

    const { pageImagesBase64 } = request.data ?? {};
    if (!Array.isArray(pageImagesBase64) || pageImagesBase64.length === 0) {
      throw new HttpsError("invalid-argument", "'pageImagesBase64' must be a non-empty array.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const imageParts = pageImagesBase64.map((b64) => ({
      inlineData: { mimeType: "image/jpeg", data: b64 },
    }));

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: buildGenerateMinutesPrompt() }, ...imageParts] }],
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: generateMinutesSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("generateMinutes: Gemini call failed", err);
      throw new HttpsError("internal", "Failed to generate minutes from these notes. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any minutes.");
    }

    try {
      return JSON.parse(text) as GenerateMinutesResponse;
    } catch (err) {
      console.error("generateMinutes: response was not valid JSON", text);
      throw new HttpsError("internal", "The minutes response could not be parsed.");
    }
  }
);
