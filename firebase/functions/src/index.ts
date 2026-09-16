import { onCall, onRequest, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
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

// The cheap tier — roughly 1/7 the input and 1/9 the output price of
// GEMINI_MODEL, and noticeably faster. Used only by "Stable Marker"
// (gradeMarkingScriptConcise's `lightweight` mode, 2026-09-10, per
// explicit request for "a more affordable one that can be used to mark
// even simple class tests"): plain marking + scoring, no answer-location
// / on-image annotation work. Verified live 2026-09-10 (2.5-flash-lite is
// "no longer available to new users" — Google's own error points here).
// Bump if deprecated, same as GEMINI_MODEL.
const GEMINI_MODEL_LITE = "gemini-3.5-flash-lite";

// A depleted prepay balance / quota is not transient — every Gemini-calling
// function should surface it plainly instead of a generic "try again",
// same as gradeMarkingScriptConcise already does. Returns the HttpsError to
// throw, or null if `err` isn't a quota/billing error (caller should fall
// back to its own generic message in that case).
function quotaExhaustedError(err: unknown): HttpsError | null {
  const msg = String((err as { message?: unknown })?.message ?? err);
  if (!/RESOURCE_EXHAUSTED|prepayment|credits are depleted|quota|\b429\b/i.test(msg)) return null;
  return new HttpsError(
    "resource-exhausted",
    "The app's AI service has run out of prepaid credit. This (and other AI features) will " +
      "work again once the Gemini API billing balance is topped up.",
  );
}

type NotesFormat = "bullet" | "paragraph";

interface GenerateTeachingNotesRequest {
  topic: string;
  subtopic?: string;
  // Required (2026-09-03) — real, reported bug: without an explicit
  // subject, a generic/short topic name (e.g. "Measurement", "Energy",
  // "Cells") gave the model nothing to disambiguate against its own
  // general knowledge, and it could drift into writing about a different
  // subject's version of that same topic name entirely. See buildPrompt's
  // use of this for the actual anti-hallucination instruction.
  subject: string;
  grade?: string;
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
    `Subject: ${req.subject}`,
    req.grade ? `Grade/Form: ${req.grade}` : null,
    `Topic: ${req.topic}`,
    req.subtopic ? `Sub-topic: ${req.subtopic}` : null,
    "",
    "Syllabus context — ground every claim in this and do not introduce content outside its scope:",
    req.syllabusContext,
    "",
    formatInstruction,
    `IMPORTANT: These notes are exclusively for the ${req.subject} subject. Some topic names ` +
      "sound similar across different subjects (e.g. a topic called \"Cells\" could mean biological " +
      `cells or electrical/battery cells) — write ONLY about what this topic means within ${req.subject}, ` +
      "as shown by the syllabus context above, never a different subject's version of a similarly-named " +
      "topic, even if that other subject's meaning is more common in general knowledge.",
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

    const { topic, subtopic, subject, grade, syllabusContext, format, maxLength } = request.data ?? {};

    if (typeof topic !== "string" || topic.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'topic' is required.");
    }
    // Required (2026-09-03) — see GenerateTeachingNotesRequest's own doc
    // comment on why: without this, a generic topic name had nothing to
    // anchor the model to the right subject.
    if (typeof subject !== "string" || subject.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'subject' is required.");
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
    if (grade !== undefined && typeof grade !== "string") {
      throw new HttpsError("invalid-argument", "'grade' must be a string if provided.");
    }
    if (maxLength !== undefined && maxLength !== "page") {
      throw new HttpsError("invalid-argument", "'maxLength' must be 'page' if provided.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const req: GenerateTeachingNotesRequest = { topic, subtopic, subject, grade, syllabusContext, format, maxLength };

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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to generate teaching notes. Please try again.");
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
  // Required (2026-09-03) — same real, reported hallucination bug fixed in
  // GenerateTeachingNotesRequest: without an explicit subject, a generic
  // topic name gave the model nothing to disambiguate against its own
  // general knowledge.
  subject: string;
  grade?: string;
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
  // "Priority Content Area" (2026-09-12, per explicit request) — a short
  // (<=5 word) teacher-typed phrase naming specific content the lesson
  // should make roughly HALF its real substance about, e.g. "rise and
  // fall of Shaka Zulu" within a wider "Mfecane" topic. See
  // buildLessonPlanPrompt's own use of this and priorityContext below.
  priorityPhrase?: string;
  // Real, on-device findings the CLIENT already gathered about
  // priorityPhrase (from this topic, the rest of the syllabus, or the
  // Subject Content Database — see PriorityContentResolver, Flutter
  // side). When absent (nothing found on-device), this function does one
  // real online search of its own instead — see resolvePriorityContent.
  priorityContext?: string;
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
              "1-3 short sentences of REAL, specific action for the teacher at this stage — never generic " +
              "filler with no subject content in it, but also never a restated list of the objectives or " +
              "competencies themselves (those are already printed in full elsewhere in the document - " +
              "referring back to them, e.g. 'covering the competencies above', is enough here).",
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

// "Priority Content Area" (2026-09-12, per explicit request): the teacher
// directly asked for this specific content to make up roughly half the
// lesson — a much stronger, deliberate signal than the general
// subjectContentExcerpt grounding above, which is why it gets its own,
// more forceful instruction block rather than being folded into that one.
function buildPriorityContentSection(req: GenerateLessonPlanRequest): string {
  if (!req.priorityPhrase || req.priorityPhrase.trim().length === 0) return "";
  const phrase = req.priorityPhrase.trim();
  const context = req.priorityContext?.trim();
  return [
    "",
    `PRIORITY CONTENT AREA — the teacher has specifically asked to emphasize: "${phrase}".`,
    "Roughly HALF of this lesson's real substance — especially the Teacher's Role across the " +
      "progression stages, and the rationale — must be genuinely about this specific content, not just " +
      "a passing mention. The other half stays the normal topic content above. Weave the two together " +
      "so the lesson reads as ONE coherent whole (e.g. use the priority content as a worked example, a " +
      "case study, or the concrete instance of the wider topic's concept) — never as two disconnected " +
      "halves bolted together.",
    context
      ? `Real, sourced notes on "${phrase}" to ground this in:\n${context}`
      : `No sourced notes on "${phrase}" were found in this app's own syllabus/content data or online. ` +
        "Cover it at a genuinely accurate, general/introductory level from your own subject knowledge " +
        "rather than inventing specific facts, dates, or figures you're not confident of.",
    "Never mention where any of this content came from (this app's own data, a search, or general " +
      "knowledge) — write it as an ordinary part of the lesson, with no source labels or citations " +
      "naming any curriculum, module, or search process.",
  ].join("\n");
}

function buildLessonPlanPrompt(req: GenerateLessonPlanRequest): string {
  return [
    "Write a lesson plan for a Zambian secondary-school teacher, for exactly one lesson period, " +
      "covering only the syllabus content below — do not introduce content outside its scope, and do " +
      "not pad any field to fill space.",
    "",
    `Subject: ${req.subject}`,
    req.grade ? `Grade/Form: ${req.grade}` : null,
    `Topic: ${req.topic}`,
    req.subtopic ? `Sub-topic: ${req.subtopic}` : null,
    "",
    "Syllabus context — the lesson MUST cover every one of these and nothing else:",
    ...req.competencies.map((c) => `- ${c}`),
    ...req.objectives.map((o) => `- ${o}`),
    "",
    `IMPORTANT: This lesson is exclusively for the ${req.subject} subject. Some topic names sound ` +
      "similar across different subjects — write ONLY about what this topic means within " +
      `${req.subject}, as shown by the syllabus content above, never a different subject's version ` +
      "of a similarly-named topic, even if that other subject's meaning is more common in general " +
      "knowledge.",
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
        "doesn't cover, and never contradict what's given here. This material may have been saved " +
        "under a different curriculum revision than this exact lesson's own (e.g. CBC vs OBC) - use it " +
        "freely for real subject content, but NEVER name or reference which curriculum/module/revision " +
        "it came from anywhere in your output; write as if it's simply this subject's own established " +
        "content:\n" +
        `${req.subjectContentExcerpt}\n`
      : null,
    buildPriorityContentSection(req),
    `Lesson stages, in order: ${req.progressionStages.join(", ")}. Produce exactly one progression ` +
      "entry per stage, in that order, with Teacher's Role, Learners' Role, and Assessment Criteria " +
      "specific to this lesson's actual content.",
    "Keep every field concise — a working document a teacher reads in the classroom, not an essay. This " +
      "matters especially for Teacher's Role: every stage's entry appears together in ONE document (not " +
      "just one stage on its own), so keep each one to 1-3 short sentences and never restate the full " +
      "objectives/competencies list inside it — those already appear in full elsewhere in the document, " +
      "so referring back to them briefly is enough.",
    "Write in plain text only — no Markdown formatting of any kind (no #, ##, ###, **, *, __, ---, or " +
      "backticks). This is a professional document a teacher will export and print, not a chat reply.",
    "If the syllabus context above is too thin to responsibly plan a full lesson, say so explicitly " +
      "in the rationale field rather than inventing content to fill the gaps.",
  ]
    .filter((line): line is string => line !== null)
    .join("\n");
}

// Last resort for "Priority Content Area" — only called when the client
// found NOTHING on-device (this topic, the rest of the syllabus, the
// Subject Content Database — see PriorityContentResolver, Flutter side).
// One real, grounded web search, scoped tightly to the phrase + subject +
// topic so it doesn't wander into an unrelated meaning of the same words.
// Same googleSearch+urlContext pattern as listCdcResources. Returns
// null (never throws) on any failure — a failed priority search still
// lets the main lesson plan generate normally, just without that extra
// grounding (buildPriorityContentSection covers the "nothing found" case).
async function resolvePriorityContentOnline(
  ai: GoogleGenAI,
  phrase: string,
  subject: string,
  topic: string,
  grade?: string
): Promise<string | null> {
  try {
    const response = await ai.models.generateContent({
      model: GEMINI_MODEL,
      contents: [
        `Find real, accurate facts about "${phrase}" as it relates to the ${subject} topic "${topic}"` +
          `${grade ? ` (${grade} level)` : ""}, for a Zambian secondary-school lesson. 4-8 short factual ` +
          "sentences, plain text, no headings or citations in the text itself. If you cannot find " +
          "anything genuinely relevant, say so in one sentence instead of guessing.",
      ],
      config: { tools: [{ urlContext: {} }, { googleSearch: {} }] },
    });
    const research = response.text?.trim();
    return research && research.length > 0 ? research : null;
  } catch (err) {
    console.error("generateLessonPlan: priority content online search failed", err);
    return null;
  }
}

export const generateLessonPlan = onCall<GenerateLessonPlanRequest>(
  { secrets: [geminiApiKey], region: "us-central1", maxInstances: 5 },
  async (request): Promise<GenerateLessonPlanResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to generate a lesson plan.");
    }

    const {
      topic,
      subtopic,
      subject,
      grade,
      competencies,
      objectives,
      references,
      progressionStages,
      subjectContentExcerpt,
      priorityPhrase,
      priorityContext,
    } = request.data ?? {};

    if (typeof topic !== "string" || topic.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'topic' is required.");
    }
    // Required (2026-09-03) — see GenerateLessonPlanRequest's own doc
    // comment on why.
    if (typeof subject !== "string" || subject.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'subject' is required.");
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
    if (grade !== undefined && typeof grade !== "string") {
      throw new HttpsError("invalid-argument", "'grade' must be a string if provided.");
    }
    if (references !== undefined && typeof references !== "string") {
      throw new HttpsError("invalid-argument", "'references' must be a string if provided.");
    }
    if (subjectContentExcerpt !== undefined && typeof subjectContentExcerpt !== "string") {
      throw new HttpsError("invalid-argument", "'subjectContentExcerpt' must be a string if provided.");
    }
    if (priorityPhrase !== undefined && typeof priorityPhrase !== "string") {
      throw new HttpsError("invalid-argument", "'priorityPhrase' must be a string if provided.");
    }
    if (priorityContext !== undefined && typeof priorityContext !== "string") {
      throw new HttpsError("invalid-argument", "'priorityContext' must be a string if provided.");
    }
    if (competencies.length === 0 && objectives.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "At least one competency or objective is required — a lesson plan cannot be grounded in nothing."
      );
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

    // Priority Content Area: only reach for a real online search when the
    // client found nothing on-device at all (priorityPhrase set,
    // priorityContext absent) — the client already tried the topic, the
    // rest of the syllabus, and the Subject Content Database first.
    let resolvedPriorityContext = priorityContext;
    if (priorityPhrase && priorityPhrase.trim().length > 0 && (!priorityContext || priorityContext.trim().length === 0)) {
      resolvedPriorityContext = (await resolvePriorityContentOnline(ai, priorityPhrase, subject, topic, grade)) ?? undefined;
    }

    const req: GenerateLessonPlanRequest = {
      topic,
      subtopic,
      subject,
      grade,
      competencies,
      objectives,
      references,
      progressionStages,
      subjectContentExcerpt,
      priorityPhrase,
      priorityContext: resolvedPriorityContext,
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to generate a lesson plan. Please try again.");
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
// generateRequiredCoreTopics — "Required Core Topics" on Scheme of Work
// (2026-09-12, per explicit request): a teacher names up to 3 topics they
// consider necessary that don't show up (or are buried inside a bigger
// topic, e.g. "rise and fall of Shaka Zulu" hidden inside "The Mfecane")
// in the generated scheme, and the app adds real, sourced content for
// them. This function is ONLY called for phrases the CLIENT found nothing
// for on-device (RequiredCoreTopicResolver already tried: the current
// term's own topics, the whole subject syllabus, and the Subject Content
// Database — all free and offline). Same two-step googleSearch+urlContext
// -> schema pattern as listCdcResources (tools and strict JSON schema
// output aren't reliably combinable in one Gemini call).
// ---------------------------------------------------------------------

interface GenerateRequiredCoreTopicsRequest {
  phrases: string[];
  // Real, on-device material already found for each phrase (same order,
  // parallel to `phrases`) — null/absent for a phrase nothing was found
  // for, in which case THAT phrase gets a real online search below.
  // 2026-09-13, per explicit request: content generation must always
  // happen properly, whether grounded in local material or fresh
  // research — this used to be skipped (a generic filler sentence used
  // instead) whenever local material existed. Never skip actually
  // writing a real outcome statement.
  localContexts?: (string | null)[];
  subjectName: string;
  gradeName?: string;
  curriculumName?: string;
  // Real, on-device context (e.g. a sample of this syllabus's own topic
  // names/objectives) so the research stays inside what this subject/level
  // actually covers, rather than answering the phrase in a vacuum.
  syllabusContext?: string;
}

interface RequiredCoreTopicResult {
  phrase: string;
  name: string;
  description: string;
  competencies: string[];
  objectives: string[];
}

interface GenerateRequiredCoreTopicsResponse {
  topics: RequiredCoreTopicResult[];
}

const requiredCoreTopicsSchema = {
  type: "object",
  properties: {
    topics: {
      type: "array",
      items: {
        type: "object",
        properties: {
          phrase: { type: "string", description: "Echo the exact phrase this entry answers, verbatim." },
          name: { type: "string", description: "A clean, short topic name fit for a scheme-of-work row." },
          description: { type: "string", description: "1-2 sentences, plain text, no Markdown." },
          competencies: {
            type: "array",
            items: { type: "string" },
            minItems: 2,
            maxItems: 4,
            description: "Specific-competence-style statements, in the syllabus's own action-statement style.",
          },
          objectives: {
            type: "array",
            items: { type: "string" },
            minItems: 2,
            maxItems: 4,
            description: "Learning-objective-style statements a learner should achieve.",
          },
        },
        required: ["phrase", "name", "description", "competencies", "objectives"],
        additionalProperties: false,
      },
    },
  },
  required: ["topics"],
  additionalProperties: false,
};

export const generateRequiredCoreTopics = onCall<GenerateRequiredCoreTopicsRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 180, memory: "512MiB", maxInstances: 5 },
  async (request): Promise<GenerateRequiredCoreTopicsResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to add required core topics.");
    }
    const { phrases, localContexts, subjectName, gradeName, curriculumName, syllabusContext } = request.data ?? {};
    if (!Array.isArray(phrases) || phrases.length === 0 || !phrases.every((p) => typeof p === "string")) {
      throw new HttpsError("invalid-argument", "'phrases' must be a non-empty string array.");
    }
    if (typeof subjectName !== "string" || subjectName.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'subjectName' is required.");
    }
    const cappedPhrases = phrases.slice(0, 3);
    const cappedLocalContexts: (string | null)[] = cappedPhrases.map((_, i) =>
      Array.isArray(localContexts) && typeof localContexts[i] === "string" && (localContexts[i] as string).trim().length > 0
        ? (localContexts[i] as string)
        : null
    );

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const levelText = [subjectName, gradeName, curriculumName ? `(${curriculumName})` : null]
      .filter((s) => s)
      .join(" ");

    let researchText: string | undefined;
    try {
      const researchResponse = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [
          `A teacher wants these specific topics added to a ${levelText} scheme of work, because the ` +
            "generated scheme doesn't directly show them (they may be real content buried inside a " +
            "bigger topic, or genuinely missing):",
          ...cappedPhrases.map((p, i) => {
            const local = cappedLocalContexts[i];
            return local
              ? `${i + 1}. "${p}" — real material already saved on this teacher's own device for this ` +
                  `topic (use THIS as the primary source, don't research it online):\n${local}`
              : `${i + 1}. "${p}" — nothing was found on-device for this one; research it below.`;
          }),
          syllabusContext
            ? `This syllabus's own real scope/level, for context (stay within this level of depth and ` +
              `region/period relevance, don't drift into unrelated territory):\n${syllabusContext}`
            : "",
          "For each topic marked 'research it below', find real, accurate facts from credible " +
            "educational sources (standard history/subject textbooks, established encyclopedic sources, " +
            "official curriculum material) appropriate for this level. For every topic (whether grounded " +
            "in the device material given above or freshly researched), write 4-8 factual sentences, " +
            "plain text, no citations/URLs in the text itself. If you genuinely can't find anything " +
            "credible and specific for a researched topic, say so in one sentence for that topic rather " +
            "than guessing.",
        ]
          .filter((s) => s)
          .join("\n"),
        config: { tools: [{ urlContext: {} }, { googleSearch: {} }] },
      });
      researchText = researchResponse.text;
    } catch (err) {
      console.error("generateRequiredCoreTopics: research call failed", err);
      throw new HttpsError("internal", "Could not research these topics. Please try again.");
    }
    if (!researchText) {
      throw new HttpsError("internal", "No research notes were returned.");
    }

    let text: string | undefined;
    try {
      const structureResponse = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [
          `Turn the research notes below into ${levelText} scheme-of-work entries — one per topic, in ` +
            "the same order as the original phrases, each phrase echoed back verbatim in its own entry. " +
            "Write competencies/objectives in the same competency-based action-statement style a real " +
            "Zambian syllabus uses (e.g. 'Explain...', 'Describe...', 'Analyse...'). Never fabricate a " +
            "specific fact, date, or figure the notes don't support — if the notes found nothing credible " +
            "for a topic, keep that entry general/introductory rather than inventing specifics. Never " +
            "mention where this content came from (a search, a curriculum name, a source website) " +
            "anywhere in the output — write it as ordinary syllabus content.",
          "",
          `Original phrases, in order: ${cappedPhrases.map((p) => `"${p}"`).join(", ")}`,
          "",
          "Research notes:",
          researchText,
        ].join("\n"),
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: requiredCoreTopicsSchema,
        },
      });
      text = structureResponse.text;
    } catch (err) {
      console.error("generateRequiredCoreTopics: structuring call failed", err);
      throw new HttpsError("internal", "Could not prepare these topics. Please try again.");
    }
    if (!text) {
      throw new HttpsError("internal", "No topics were returned.");
    }

    let parsed: GenerateRequiredCoreTopicsResponse;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("generateRequiredCoreTopics: response was not valid JSON", text);
      throw new HttpsError("internal", "The response could not be parsed.");
    }
    if (!Array.isArray(parsed.topics)) parsed.topics = [];
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
  "SCOPE — secondary school ONLY: Form 1 to Form 5 under the Competence-Based Curriculum " +
    "(CBC), and Grade 10 to Grade 12 under the outcome-based curriculum. This app has no use " +
    "for primary school (Grade 1-7) or early childhood education (ECE) materials — never " +
    "record a resource from either of those levels, even if you come across one while " +
    "browsing. If a listing page or resource doesn't clearly state its level/grade/form, skip " +
    "it rather than guessing it's secondary.",
  "",
  "1) CDC Teaching Modules (resourceType: 'module') — search and browse ONLY " +
    "https://library.cdcrepository.info/browse.php?level=secondary (and its pagination) to " +
    "find as many individual Teaching Module resources as you reasonably can within your " +
    "tool-call budget. Do not browse or record anything from the ?level=ece or " +
    "?level=primary listing pages — they are out of scope per SCOPE above.",
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

const cdcCacheRef = () => admin.firestore().collection("system").doc("cdcResourcesCache");

// The actual crawl: two Gemini calls (research with googleSearch+urlContext
// tools grounding real findings as free text, then a tool-free call
// reshaping that into cdcResourcesSchema) — see the module-level comment
// above CDC_CATALOG_PROMPT for why two calls instead of one. Shared by the
// weekly scheduled refresh and listCdcResources' own emergency fallback so
// there's exactly one place that does the expensive work.
async function fetchAndCacheCdcCatalog(): Promise<ListCdcResourcesResponse> {
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
    throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to fetch the CDC catalog. Please try again.");
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
    throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to fetch the CDC catalog. Please try again.");
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

  const response: ListCdcResourcesResponse = {
    resources: parsed.resources ?? [],
    fetchedAt: new Date().toISOString(),
  };
  await cdcCacheRef().set(response);
  return response;
}

// Weekly refresh (2026-09-15, per explicit request): the CDC Digital
// Library doesn't publish new material often enough to justify checking
// more than about once a week, and doing the crawl on a fixed schedule —
// rather than lazily on whichever device happens to ask first — means
// exactly one real (paid, googleSearch+urlContext-grounded) crawl happens
// per week, full stop, regardless of how many teachers/testers use the
// app or how often the client-side "is it due" check gets asked. See the
// billing investigation this replaced (was ~30 live crawls/day with no
// caching at all) for why this matters. Wednesday afternoon has no
// particular significance beyond being a plain, predictable slot outside
// both weekend and Monday/Friday edges.
export const refreshCdcResourcesWeekly = onSchedule(
  { schedule: "0 14 * * 3", timeZone: "Africa/Lusaka", secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 480, memory: "512MiB" },
  async () => {
    await fetchAndCacheCdcCatalog();
  }
);

// A cache more than this stale means the Wednesday schedule has silently
// failed for two cycles running — worth a live emergency fetch rather than
// leaving the app on a catalog that's gone stale indefinitely. Well above
// the normal ~7-day cadence so a single missed run is never a problem.
const CDC_CACHE_STALE_FALLBACK_MS = 10 * 24 * 60 * 60 * 1000;

export const listCdcResources = onCall<Record<string, never>>(
  // Gemini stopgap (2026-08-27, see top-of-file comment) for the *data*;
  // as of 2026-09-15 this function itself no longer does the crawl on the
  // normal path — refreshCdcResourcesWeekly does, on its own schedule, and
  // this just serves whatever it last cached. The live Gemini path below
  // only runs as an emergency fallback (cache missing or badly stale).
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 480, memory: "512MiB", maxInstances: 3 },
  async (request): Promise<ListCdcResourcesResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to fetch CDC resources.");
    }

    const cached = await cdcCacheRef().get();
    if (cached.exists) {
      const data = cached.data() as { resources?: CdcResource[]; fetchedAt?: string } | undefined;
      const fetchedAt = data?.fetchedAt ? new Date(data.fetchedAt).getTime() : 0;
      if (data?.resources && Date.now() - fetchedAt < CDC_CACHE_STALE_FALLBACK_MS) {
        return { resources: data.resources, fetchedAt: data.fetchedAt! };
      }
    }

    return fetchAndCacheCdcCatalog();
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
  // Optional (2026-09-03) — this function's own hallucination risk is
  // already low (it condenses the already-generated, already-grounded
  // notesText rather than researching fresh), but the extra grounding
  // costs nothing when the caller has it — see buildSlidePrompt.
  subject?: string;
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
    req.subject ? `Subject: ${req.subject}` : null,
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

    const { topic, subtopic, subject, notesText, notesFormat } = request.data ?? {};

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
    if (subject !== undefined && typeof subject !== "string") {
      throw new HttpsError("invalid-argument", "'subject' must be a string if provided.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const req: GenerateSlideOutlineRequest = { topic, subtopic, subject, notesText, notesFormat };

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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to generate slide outline. Please try again.");
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
// generateFreeTopicNotes — "Generate Notes & Slides by Topic" (2026-09-04):
// a topic the teacher types directly, not tied to any bundled syllabus
// topic at all — unlike generateTeachingNotes/generateLessonPlan, there is
// deliberately no syllabus context to ground this in; the whole point is
// covering topics the bundled curriculum doesn't have. Three fixed output
// shapes, per explicit request: 'paragraph' (flowing prose, up to 700
// words), 'bulletin' (bullet points, thorough, up to ~6 printed pages),
// 'slides' (exactly 6 slides, 4-5 bullets each). Per explicit request,
// this capability is not labeled as AI-powered anywhere in the app's own
// UI — this comment is the only place that says so, for the project's own
// record; the content itself still carries the same no-fabrication
// instruction as every other AI call in this app.
// ---------------------------------------------------------------------

type FreeTopicFormat = "paragraph" | "bulletin" | "slides";

interface GenerateFreeTopicNotesRequest {
  topic: string;
  format: FreeTopicFormat;
}

interface GenerateFreeTopicNotesResponse {
  text?: string;
  deckTitle?: string;
  slides?: SlideOutlineSlide[];
}

const freeTopicSlideSchema = {
  type: "object",
  properties: {
    deckTitle: { type: "string" },
    slides: {
      type: "array",
      minItems: 6,
      maxItems: 6,
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          bullets: { type: "array", items: { type: "string" }, minItems: 4, maxItems: 5 },
        },
        required: ["title", "bullets"],
        additionalProperties: false,
      },
    },
  },
  required: ["deckTitle", "slides"],
  additionalProperties: false,
};

function buildFreeTopicPrompt(topic: string, format: "paragraph" | "bulletin"): string {
  const common = [
    `Topic: ${topic}`,
    "",
    "Draw on well-established, credible general knowledge appropriate for a secondary-school teaching " +
      "context. Do not fabricate facts, statistics, or sources.",
  ];
  if (format === "paragraph") {
    return [
      "Write detailed, well-organized teaching notes on the topic below, as flowing prose paragraphs " +
        "under short subheadings, no more than 700 words in total.",
      ...common,
      "Write only the notes themselves — no preamble, no meta-commentary about the word count or format.",
      "Write in plain text only — no Markdown formatting of any kind (no #, ##, ###, **, *, __, ---, or " +
        "backticks).",
    ].join("\n");
  }
  return [
    "Summarize the topic below as clearly organized bullet points, grouped under short subheadings, " +
      "thorough enough to fill up to approximately 6 printed pages (roughly 2500-3000 words of bullets) " +
      "— stop naturally once the topic is genuinely covered, even if that's fewer than 6 pages; never pad " +
      "with filler just to reach the target.",
    ...common,
    "Write only the notes themselves — no preamble, no meta-commentary about the word count or format.",
    "Write in plain text only — no Markdown formatting of any kind (no #, ##, ###, **, *, __, ---, or " +
      "backticks).",
  ].join("\n");
}

function buildFreeTopicSlidePrompt(topic: string): string {
  return [
    `Topic: ${topic}`,
    "",
    "Produce a PowerPoint slide deck outline summarizing this topic: exactly 6 slides, each with 4 to 5 " +
      "concise bullet points in point form (short phrases, not full sentences). No more and no fewer " +
      "than 6 slides.",
    "Draw on well-established, credible general knowledge appropriate for a secondary-school teaching " +
      "context. Do not fabricate facts, statistics, or sources.",
    "Write only the slide outline — no preamble or meta-commentary.",
    "Write in plain text only — no Markdown formatting of any kind (no #, ##, ###, **, *, __, ---, or " +
      "backticks) anywhere in the deck title, slide titles, or bullets.",
  ].join("\n");
}

export const generateFreeTopicNotes = onCall<GenerateFreeTopicNotesRequest>(
  { secrets: [geminiApiKey], region: "us-central1", maxInstances: 5 },
  async (request): Promise<GenerateFreeTopicNotesResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to generate notes.");
    }

    const { topic, format } = request.data ?? {};
    if (typeof topic !== "string" || topic.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'topic' is required.");
    }
    if (format !== "paragraph" && format !== "bulletin" && format !== "slides") {
      throw new HttpsError("invalid-argument", "'format' must be 'paragraph', 'bulletin', or 'slides'.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

    if (format === "slides") {
      let text: string | undefined;
      try {
        const response = await ai.models.generateContent({
          model: GEMINI_MODEL,
          contents: buildFreeTopicSlidePrompt(topic),
          config: {
            responseMimeType: "application/json",
            responseJsonSchema: freeTopicSlideSchema,
          },
        });
        text = response.text;
      } catch (err) {
        console.error("generateFreeTopicNotes (slides): Gemini call failed", err);
        throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to generate slides. Please try again.");
      }
      if (!text) {
        throw new HttpsError("internal", "The AI did not return any slides.");
      }
      try {
        const parsed = JSON.parse(text) as { deckTitle: string; slides: SlideOutlineSlide[] };
        return { deckTitle: parsed.deckTitle, slides: parsed.slides };
      } catch (err) {
        console.error("generateFreeTopicNotes (slides): response was not valid JSON", text);
        throw new HttpsError("internal", "The slide response could not be parsed.");
      }
    }

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: buildFreeTopicPrompt(topic, format),
      });
      text = response.text;
    } catch (err) {
      console.error("generateFreeTopicNotes: Gemini call failed", err);
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to generate notes. Please try again.");
    }
    if (!text) {
      throw new HttpsError("internal", "The AI did not return any text.");
    }
    return { text };
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

// "Learn from AI-marking corrections" (2026-09-08, per explicit request,
// clarified via AskUserQuestion — one half of "get smarter with more
// usage"): a real, past correction a teacher made to this SAME subject's
// AI grading (see MarkingCorrectionRepository, client-side) — a helpful
// prior about how strictly/leniently to mark, never ground truth for
// THIS script. See buildGradingPrompt's own use of it.
interface PriorCorrectionHint {
  questionLabel: string;
  maxMarks: number;
  aiMarks: number;
  correctedMarks: number;
  answerExcerpt: string;
}

// ---------------------------------------------------------------------
// AI Marking Rules Engine (2026-09-08, per explicit request — "the front
// page is the law"): a marking key's OWN stated conventions always win;
// these are the sensible defaults applied when it states nothing more
// specific, plus subject-shaped grading texture layered on top. See
// Smart_Teacher_AI_Marking_Rules_Engine-1.md (the user's own design doc)
// for the full rationale — this is that document's Sections 2-4 turned
// into real prompt text.
// ---------------------------------------------------------------------

const UNIVERSAL_MARKING_CONVENTIONS = [
  "Universal marking conventions (apply these UNLESS this scheme's own stated conventions above override " +
    "them for a specific point):",
  "- One bullet point/keyword listed in the expected answer = 1 mark, unless a maxMarks value or the " +
    "scheme's own conventions say otherwise.",
  "- A question's maxMarks is a HARD CAP - never award more than that, however good the answer.",
  "- Where the expected answer lists alternatives separated by '/', any one of them is acceptable.",
  "- For short factual answers (a name, date, term, single fact): correct or zero - no partial marks for " +
    "an incorrect or incomplete factual answer, unless the scheme's own conventions explicitly allow it.",
  "- For a passage/comprehension-based question: an answer in the candidate's own words is acceptable " +
    "provided the meaning genuinely matches what's expected - it does not need to match the expected " +
    "wording verbatim.",
  "- For an essay/extended-response question: award marks for any point that is relevant and factually " +
    "accurate, even where it is not explicitly listed in the expected answer - this is 'reasonable " +
    "equivalence' judgment, and every mark awarded this way must be marked markingBasis='reasonable_" +
    "equivalence' (see below), never treated as if it were an exact match.",
  "- Exact facts (dates, specific names, figures, precise terminology) must match precisely where the " +
    "expected answer names one specifically - a related-but-different term is not the same as the exact " +
    "one the key asks for.",
].join("\n");

// Subject-shaped grading texture. HISTORY is fully specified from the
// user's own real, detailed ECZ standards. The other five are a DRAFT
// first pass from general ECZ/Zambian-curriculum convention knowledge,
// per explicit request to draft them now rather than wait - NOT yet
// verified against a real marking key front page for that subject. Each
// is clearly marked as a draft in its own comment; refine once the
// teacher supplies a real sample (matches the user's own doc, which asks
// for exactly that).
const SUBJECT_MODULES: { matches: RegExp; text: string }[] = [
  {
    // Real, fully specified — from the user's own detailed ECZ History
    // standards (2167/1, 2167/2).
    matches: /\bhistory\b/i,
    text: [
      "Subject-specific guidance for HISTORY:",
      "- Source-based sections (map, picture, passage, chart, table, timeline): most items are worth 1 " +
        "mark; a correct answer is a single word, name, date, or short phrase - never more than 2 " +
        "sentences. A map/picture question needs the EXACT specific term the key asks for, not a broader " +
        "correct-but-imprecise term (e.g. a specific clan/place name, not just a general region).",
      "- Essay sections: mark-split brackets apply per sub-part exactly. Award marks for any historically " +
        "accurate point, not only points explicitly listed in the key - flag these as markingBasis=" +
        "'reasonable_equivalence'.",
      "- Dates must be exact.",
      "- Paper 2167/1 covers Central + Southern African History; Paper 2167/2 covers World History only - " +
        "these are never mixed, so an answer drawing on the wrong paper's content is not creditable even " +
        "if factually accurate about that other region/era.",
    ].join("\n"),
  },
  {
    // DRAFT - general ECZ Mathematics convention, not yet checked against
    // a real marking key front page.
    matches: /\bmath(s|ematics)?\b/i,
    text: [
      "Subject-specific guidance for MATHEMATICS (draft convention, not yet confirmed against a real " +
        "marking key for this exact paper):",
      "- Distinguish method marks from accuracy marks where working is shown: correct method/working " +
        "shown earns credit even if the final answer is wrong; a bare correct final answer with no working " +
        "at all may not earn full marks where the expected answer implies working was required.",
      "- Apply the 'follow-through' principle: if a candidate makes an early error but then correctly " +
        "applies the right method to their OWN (now-wrong) intermediate result, later steps still earn " +
        "their own marks - do not zero out an entire multi-step answer for one early slip.",
      "- Units and significant figures matter only where the expected answer itself specifies them.",
    ].join("\n"),
  },
  {
    // DRAFT - general ECZ English convention, not yet checked against a
    // real marking key front page.
    matches: /\benglish\b/i,
    text: [
      "Subject-specific guidance for ENGLISH (draft convention, not yet confirmed against a real marking " +
        "key for this exact paper):",
      "- Comprehension short-answers: an own-words paraphrase is acceptable when the meaning matches, not " +
        "just a word-for-word match.",
      "- A composition/essay question is marked holistically against content, language, and organisation " +
        "rather than a bullet-point key - award marks by overall quality across those three, and mark " +
        "every such award markingBasis='reasonable_equivalence' since it is a judgment call, not an exact " +
        "match.",
      "- Grammar/summary-type questions: match closely to the expected answer, per the scheme's own stated " +
        "tolerance.",
    ].join("\n"),
  },
  {
    // DRAFT - general ECZ Religious Education convention (both 2044 and
    // 2046 syllabi), not yet checked against a real marking key.
    matches: /\breligious education\b|\bR\.?E\.?\b|\b204[46]\b/i,
    text: [
      "Subject-specific guidance for RELIGIOUS EDUCATION (draft convention, not yet confirmed against a " +
        "real marking key for this exact paper):",
      "- Source/short-answer sections behave like a factual short-answer item: exact or zero, per the " +
        "universal conventions above.",
      "- Essay sections: award marks for any relevant, doctrinally/factually accurate point, flagged as " +
        "markingBasis='reasonable_equivalence' where not explicitly listed.",
      "- Where a question specifically asks for a scripture reference or the name of a religious text, " +
        "that reference/name itself must be exact even when the surrounding explanation is well-argued.",
    ].join("\n"),
  },
  {
    // DRAFT - general ECZ Geography convention, not yet checked against a
    // real marking key front page.
    matches: /\bgeography\b/i,
    text: [
      "Subject-specific guidance for GEOGRAPHY (draft convention, not yet confirmed against a real marking " +
        "key for this exact paper):",
      "- Map-reading and diagram-labelling items need the EXACT specific term the key asks for, the same " +
        "exact-term rule as a History map question - a broader or related term is not the same as the " +
        "specific one required.",
      "- Non-map short-answer and essay sections otherwise follow the same rules as History's source-based " +
        "and essay sections respectively.",
    ].join("\n"),
  },
  {
    // DRAFT - general ECZ Civic Education convention, not yet checked
    // against a real marking key front page.
    matches: /\bcivic education\b|\bcivics\b/i,
    text: [
      "Subject-specific guidance for CIVIC EDUCATION (draft convention, not yet confirmed against a real " +
        "marking key for this exact paper):",
      "- Source/short-answer sections behave like a factual short-answer item: exact or zero, per the " +
        "universal conventions above.",
      "- Essay sections: award marks for any relevant, factually accurate point, flagged as markingBasis=" +
        "'reasonable_equivalence' where not explicitly listed in the key.",
    ].join("\n"),
  },
];

/// Best-effort subject-name match against [SUBJECT_MODULES] - substring/
/// regex match, same tolerant spirit as this app's other free-text
/// subject matching (e.g. RelatedMarkingKeyFinder, client-side). Returns
/// null (generic universal-conventions-only grading, today's existing
/// behaviour) when nothing matches - never a wrong subject's texture
/// applied to an unrelated one.
function selectSubjectModule(subjectName: string | undefined): string | null {
  if (!subjectName || !subjectName.trim()) return null;
  for (const module of SUBJECT_MODULES) {
    if (module.matches.test(subjectName)) return module.text;
  }
  return null;
}

function examStandardGuidance(examStandard: string | null | undefined): string {
  if (examStandard === "NATIONAL_MOCK") {
    return (
      "This is a NATIONAL MOCK examination - mark it to the IDENTICAL standard as the real ECZ national " +
      "exam. Do not soften or go easier than a real national exam marker would; do not be harsher either " +
      "- match the real standard exactly, neither curved up nor down."
    );
  }
  if (examStandard === "SCHOOL_CA") {
    return (
      "This is one component of a school's own Continuous Assessment (a Mid-Term or End-of-Term test) - " +
      "mark it fairly and accurately per the scheme's own stated conventions, exactly as you would any " +
      "other script. This mark will later be combined with the school's other CA component into a " +
      "weighted term mark outside of this grading step - your job here is only to mark THIS script " +
      "correctly against its own key, not to apply any special leniency because it is a school test " +
      "rather than a national exam."
    );
  }
  return "";
}

interface GradeMarkingScriptRequest {
  pageImagesBase64: string[];
  questions: GradeMarkingScriptQuestion[];
  preSegmentedAnswers?: PreSegmentedAnswerHint[];
  priorCorrections?: PriorCorrectionHint[];
  // Rules Engine (2026-09-08): the scheme's own subject, front-page-stated
  // conventions (see deriveMarkingKeyFromQuestionPaper's markConventions),
  // and marking standard - all optional, all silently skipped when absent
  // (an older client, or a scheme saved before these existed) rather than
  // blocking grading on their absence.
  subjectName?: string;
  markConventions?: string[];
  examStandard?: "NATIONAL_MOCK" | "SCHOOL_CA" | null;
}

interface GradedAnswerResult {
  questionLabel: string;
  transcribedAnswer: string;
  marksAwarded: number;
  confidence: "high" | "medium" | "low";
  // Rules Engine confidence tagging (2026-09-08): DISTINCT from
  // `confidence` (which is about handwriting/transcription legibility) -
  // this is about whether the mark itself came from an exact key match or
  // required subject-matter judgment. 'reasonable_equivalence' should
  // never be paired with confidence='high' (see buildGradingPrompt).
  markingBasis: "exact_match" | "reasonable_equivalence" | "not_applicable";
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
          markingBasis: { type: "string", enum: ["exact_match", "reasonable_equivalence", "not_applicable"] },
        },
        required: ["questionLabel", "transcribedAnswer", "marksAwarded", "confidence", "markingBasis"],
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
  preSegmentedAnswers?: PreSegmentedAnswerHint[],
  priorCorrections?: PriorCorrectionHint[],
  subjectName?: string,
  markConventions?: string[],
  examStandard?: "NATIONAL_MOCK" | "SCHOOL_CA" | null
): string {
  const schemeText = questions
    .map((q) => `${q.label} (max ${q.maxMarks} marks): expected answer/keywords — ${q.expectedAnswerOrKeywords}`)
    .join("\n");

  // Rules Engine (2026-09-08): this scheme's OWN stated conventions come
  // first and take priority — the universal defaults and subject module
  // below explicitly say they apply only where this doesn't override them.
  const schemeConventionsSection =
    markConventions && markConventions.length > 0
      ? [
          "",
          "This marking scheme's own front page states these conventions — they take priority over " +
            "everything below wherever they conflict:",
          markConventions.map((c) => `- ${c}`).join("\n"),
        ].join("\n")
      : "";

  const subjectModuleText = selectSubjectModule(subjectName);
  const subjectModuleSection = subjectModuleText ? `\n${subjectModuleText}` : "";

  const examStandardText = examStandardGuidance(examStandard);
  const examStandardSection = examStandardText ? `\n${examStandardText}` : "";

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

  // "Learn from AI-marking corrections" — real corrections THIS teacher
  // already made to THIS subject's past AI-graded scripts, most recent
  // first. A prior, not ground truth for this specific script's own
  // answers: use it to calibrate how strictly/leniently this teacher
  // expects a similar answer to be marked, never to copy a mark or
  // answer verbatim onto an unrelated question.
  const correctionsSection =
    priorCorrections && priorCorrections.length > 0
      ? [
          "",
          "Known correction patterns for this subject — this teacher previously corrected the AI's own " +
            "marking on these real past answers. Use them ONLY to calibrate how strictly or leniently this " +
            "teacher expects a similar kind of answer to be marked (e.g. whether partial credit is generous " +
            "or strict for this subject) — never apply one of these marks to a different, unrelated answer " +
            "just because the question label happens to match:",
          priorCorrections
            .map(
              (c) =>
                `${c.questionLabel} (max ${c.maxMarks}): an answer like "${c.answerExcerpt}" — AI gave ` +
                `${c.aiMarks}, teacher corrected to ${c.correctedMarks}.`
            )
            .join("\n"),
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
      "question's maximum — partial credit is expected and normal, not just full marks or zero. Apply the " +
      "marking conventions given below, in this priority order: this scheme's own stated conventions " +
      "first, then the subject-specific guidance, then the universal defaults.",
    "4. For EACH answer, set markingBasis: 'exact_match' when the mark came directly from a listed " +
      "expected answer or one of its stated alternatives, with no judgment call involved; " +
      "'reasonable_equivalence' when you awarded a mark for a point that is relevant and accurate but was " +
      "NOT explicitly listed in the expected answer (a genuine judgment call on your part); " +
      "'not_applicable' for a question with no such judgment involved either way (e.g. no answer found, or " +
      "the question is objective/multiple-choice with only one possible interpretation).",
    "5. Give a confidence level for EACH answer: 'high' only when both the handwriting was clearly " +
      "legible AND you're confident the mark awarded is correct — NEVER 'high' when markingBasis is " +
      "'reasonable_equivalence' (a judgment call always warrants a teacher's review, however confident you " +
      "are in it); 'low' whenever either the handwriting was hard to read, the answer was ambiguous, or " +
      "you're unsure the mark is right; 'medium' otherwise. Confidence reflects your own uncertainty " +
      "honestly — it is what determines whether a teacher is required to double-check this specific " +
      "answer, so do not default to 'high'.",
    "6. Separately, write 3 to 5 short observations about this candidate's performance on THIS script — " +
      "specific strengths and/or weaknesses grounded in what the marking scheme actually asked for (e.g. " +
      "'Consistently applied the correct formula but made arithmetic slips in Q2 and Q4' or 'Strong on " +
      "definitions (Q1, Q3) but answers to application questions were too brief to earn full marks'), not " +
      "generic praise or criticism that could apply to any script. Base these only on what you actually " +
      "observed while grading, never on assumptions about the candidate.",
    "",
    "Marking scheme:",
    schemeText,
    schemeConventionsSection,
    subjectModuleSection,
    examStandardSection,
    "",
    UNIVERSAL_MARKING_CONVENTIONS,
    hintSection,
    correctionsSection,
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

    const { pageImagesBase64, questions, preSegmentedAnswers, priorCorrections, subjectName, markConventions, examStandard } =
      request.data ?? {};
    if (!Array.isArray(pageImagesBase64) || pageImagesBase64.length === 0) {
      throw new HttpsError("invalid-argument", "'pageImagesBase64' must be a non-empty array.");
    }
    if (!Array.isArray(questions) || questions.length === 0) {
      throw new HttpsError("invalid-argument", "'questions' must be a non-empty array.");
    }
    // Same defensive cap already applied to preSegmentedAnswers elsewhere in
    // this app (see generateSchemeOfWorkContent's 20-item cap) — a client
    // bug sending an unbounded list should shrink to nothing usable, not
    // blow up prompt size/cost.
    const cappedPriorCorrections =
      Array.isArray(priorCorrections) ? priorCorrections.slice(0, 15) : undefined;
    const cappedMarkConventions = Array.isArray(markConventions) ? markConventions.slice(0, 20) : undefined;

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

    const imageParts = pageImagesBase64.map((b64) => ({
      inlineData: { mimeType: "image/jpeg", data: b64 },
    }));

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [
          {
            role: "user",
            parts: [
              {
                text: buildGradingPrompt(
                  questions,
                  preSegmentedAnswers,
                  cappedPriorCorrections,
                  subjectName,
                  cappedMarkConventions,
                  examStandard
                ),
              },
              ...imageParts,
            ],
          },
        ],
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: gradeMarkingScriptSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("gradeMarkingScript: Gemini call failed", err);
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to grade this script. Please try again.");
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
// gradeMarkingScriptConcise — "Concise Marking" (Scan Marker, 2026-09-11,
// per explicit request): the same real grading gradeMarkingScript already
// does, PLUS asking the model to point at exactly where on the original
// photographed page each answer's own mark belongs, so the client can
// draw a real tick/cross directly onto a copy of the actual script image
// — "a tick on the correct answer on the image of the student's script
// right on the correct question's answer being marked, or an x... if it
// is a wrong one."
//
// A SEPARATE function from gradeMarkingScript, not a shared schema change
// to it, per this app's standing "don't disrupt an established function"
// principle — every teacher not using Concise Marking keeps the exact
// same grading behaviour, unaffected by this. Shares buildGradingPrompt's
// own Rules Engine building blocks (universal conventions, subject
// module, exam-standard guidance) so the real marking judgment is
// identical either way; only the extra location instructions are new.
//
// Real, disclosed limitation (per explicit request: "if there is no AI to
// make a representation on the actual image... the computer should mark
// [on] the computer generated version"): pageIndex/box are null whenever
// the model isn't confident where an answer actually sits on the page —
// never guessed just to fill the field, same "never guess, disclose
// uncertainty" principle as every other AI feature in this app. The
// CLIENT (see ScriptAnnotationService) is what actually falls back to a
// generated digital reproduction for those specific answers; this
// function's only job is grading + best-effort location.
// ---------------------------------------------------------------------

interface ConciseMarkingAnnotation {
  questionLabel: string;
  transcribedAnswer: string;
  marksAwarded: number;
  // The marks this question carries. In keyed mode this echoes the
  // scheme; in pure-AI mode (no marking key supplied) it is the mark
  // allocation the model read off the paper — or a sensible default it
  // chose when the paper shows none. The client's deterministic scorer
  // works entirely off this value.
  maxMarks: number;
  confidence: "high" | "medium" | "low";
  markingBasis: "exact_match" | "reasonable_equivalence" | "not_applicable";
  // Which section of the paper this question belongs to (verbatim from
  // the paper — e.g. "Section A", "Section C"), or null for a paper with
  // no section structure at all. Used CLIENT-side by ConciseScoreCalculator
  // to apply each section's own "answer N of M" rule before totalling.
  sectionName: string | null;
  // 0-based index into the pageImagesBase64 array this request was sent
  // with — which photographed page the student's own handwritten answer
  // for this question actually appears on. Null when not confidently
  // locatable.
  pageIndex: number | null;
  // A tight bounding box around JUST the student's own handwritten
  // answer (not the whole page, not the printed question text) -
  // [yMin, xMin, yMax, xMax], each normalized 0-1000 across the page
  // image's own real width/height (Gemini's own standard object-
  // detection coordinate convention). Null when not confidently
  // locatable, or when pageIndex is null.
  box: { yMin: number; xMin: number; yMax: number; xMax: number } | null;
}

// One section's own rules, as they are stated on the FIRST script's own
// cover / instructions page (per explicit request: "always get the
// marking instruction from the first cover page of any exam"). The client
// extracts this once, from the first script of a cohort, then feeds it
// back in as `knownRubric` for every following script so the same
// examination is scored identically without re-deriving it each time.
interface ConciseRubricSection {
  // Verbatim section label, e.g. "Section A", "Section C".
  name: string;
  // How many questions the candidate is REQUIRED to answer from this
  // section (e.g. "answer any ONE question" -> 1). Null when the paper
  // does not restrict it (answer everything in the section).
  questionsToAnswer: number | null;
  // Total marks this section is worth on the paper, exactly as the paper
  // allocates them. Null when the paper states no explicit section total.
  marksAllocated: number | null;
}

interface ConciseRubric {
  sections: ConciseRubricSection[];
  // The paper's own stated grand total (e.g. "Total: 100 marks"). Null
  // when the paper states none.
  paperTotalMarks: number | null;
  // A short plain-language digest of the cover-page instructions the
  // marking actually depended on — shown to the teacher, never acted on
  // blindly.
  instructionsSummary: string;
}

interface GradeMarkingScriptConciseResponse {
  answers: ConciseMarkingAnnotation[];
  // Populated ONLY when this request did not carry a `knownRubric` (i.e.
  // this is the first script of a cohort and the model was asked to read
  // the cover page). Null otherwise, or when the paper genuinely has no
  // section/instruction structure to extract.
  rubric: ConciseRubric | null;
  observations: string[];
}

interface GradeMarkingScriptConciseRequest {
  pageImagesBase64: string[];
  // The marking key, when the teacher has one saved and chose to use it as
  // the AUTHORITY. Omitted for the normal pure-AI path (2026-09-10, per
  // explicit request that "concise marker is supposed to be purely AI as a
  // priority") — the model then reads the questions and their marks off
  // the paper itself.
  questions?: GradeMarkingScriptQuestion[];
  // A saved marking key the app auto-detected as matching this subject —
  // passed as REFERENCE only. The model uses its expected answers where a
  // question clearly corresponds and its own subject expertise everywhere
  // else. Never the authority; never blocks marking.
  referenceQuestions?: GradeMarkingScriptQuestion[];
  // Optional extra images of the question paper / official marking guide,
  // for when the answer booklet doesn't carry the questions itself.
  // Attached AFTER the answer-script pages.
  questionPaperImagesBase64?: string[];
  subjectName?: string;
  markConventions?: string[];
  examStandard?: "NATIONAL_MOCK" | "SCHOOL_CA" | null;
  // Supplied for every script AFTER the first in a cohort — the rubric
  // already extracted from the first script's cover page. When present,
  // the model is told to score against it and NOT re-derive section rules.
  knownRubric?: ConciseRubric | null;
  // "Stable Marker" (2026-09-10): mark + score on the cheap model, with no
  // answer-location work (pageIndex/box always null) and no on-image
  // annotation downstream. Same scoring, same rubric, cheaper engine.
  lightweight?: boolean;
}

const gradeMarkingScriptConciseSchema = {
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
          maxMarks: {
            type: "number",
            description:
              "The marks this question carries. Echo the marking scheme in keyed mode; read it off the " +
              "paper's own mark allocation in pure-AI mode (choose a sensible value only if the paper " +
              "shows none).",
          },
          confidence: { type: "string", enum: ["high", "medium", "low"] },
          markingBasis: { type: "string", enum: ["exact_match", "reasonable_equivalence", "not_applicable"] },
          sectionName: {
            type: ["string", "null"],
            description:
              "Verbatim section label this question sits under on the paper (e.g. 'Section A', 'Section " +
              "C'). Null only if the paper truly has no sections.",
          },
          pageIndex: {
            type: ["integer", "null"],
            description:
              "0-based index into the images this request was sent with - which photographed page the " +
              "student's own handwritten answer for this question actually appears on. Null if not " +
              "confidently locatable - never guess.",
          },
          box: {
            type: ["object", "null"],
            description:
              "A tight bounding box around JUST the student's own handwritten answer on that page (not " +
              "the whole page, not the printed question text) - normalized 0-1000 across that page " +
              "image's own real width/height. Null if not confidently locatable, or if pageIndex is null " +
              "- never guess a location just to fill this field.",
            properties: {
              yMin: { type: "integer" },
              xMin: { type: "integer" },
              yMax: { type: "integer" },
              xMax: { type: "integer" },
            },
            required: ["yMin", "xMin", "yMax", "xMax"],
            additionalProperties: false,
          },
        },
        required: [
          "questionLabel", "transcribedAnswer", "marksAwarded", "maxMarks", "confidence", "markingBasis",
          "sectionName", "pageIndex", "box",
        ],
        additionalProperties: false,
      },
    },
    rubric: {
      type: ["object", "null"],
      description:
        "The paper's own section/instruction structure, read from the FIRST attached page (the cover / " +
        "instructions page) - ONLY when this request carried no knownRubric. Null if this request DID " +
        "carry a knownRubric, or if the paper has no section structure at all.",
      properties: {
        sections: {
          type: "array",
          items: {
            type: "object",
            properties: {
              name: { type: "string" },
              questionsToAnswer: {
                type: ["integer", "null"],
                description:
                  "How many questions the candidate MUST answer from this section (e.g. 'answer any " +
                  "TWO' -> 2). Null if the section does not restrict it.",
              },
              marksAllocated: {
                type: ["number", "null"],
                description: "Marks this section is worth on the paper. Null if the paper states none.",
              },
            },
            required: ["name", "questionsToAnswer", "marksAllocated"],
            additionalProperties: false,
          },
        },
        paperTotalMarks: { type: ["number", "null"] },
        instructionsSummary: { type: "string" },
      },
      required: ["sections", "paperTotalMarks", "instructionsSummary"],
      additionalProperties: false,
    },
    observations: {
      type: "array",
      items: { type: "string" },
      minItems: 3,
      maxItems: 8,
    },
  },
  required: ["answers", "rubric", "observations"],
  additionalProperties: false,
};

/// Best-effort recovery of a MAX_TOKENS-truncated JSON response: keep every
/// complete `answers[]` entry we can, drop a half-written trailing one, and
/// close the structure so the annotated marked script can still be
/// produced from whatever the model did return. Returns null if nothing
/// usable can be salvaged.
function salvageTruncatedConciseJson(text: string): GradeMarkingScriptConciseResponse | null {
  const start = text.indexOf('"answers"');
  if (start < 0) return null;
  const arrStart = text.indexOf("[", start);
  if (arrStart < 0) return null;

  const entries: string[] = [];
  let depth = 0;
  let entryStart = -1;
  let inString = false;
  let escaped = false;
  for (let i = arrStart + 1; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === "{") {
      if (depth === 0) entryStart = i;
      depth++;
    } else if (ch === "}") {
      depth--;
      if (depth === 0 && entryStart >= 0) {
        entries.push(text.slice(entryStart, i + 1));
        entryStart = -1;
      }
    } else if (ch === "]" && depth === 0) {
      break;
    }
  }
  if (entries.length === 0) return null;

  const parsedAnswers: ConciseMarkingAnnotation[] = [];
  for (const e of entries) {
    try {
      parsedAnswers.push(JSON.parse(e));
    } catch {
      /* skip an entry that itself won't parse */
    }
  }
  if (parsedAnswers.length === 0) return null;
  return { answers: parsedAnswers, rubric: null, observations: [] };
}

function buildConciseMarkingPrompt(
  questions: GradeMarkingScriptQuestion[],
  subjectName?: string,
  markConventions?: string[],
  examStandard?: "NATIONAL_MOCK" | "SCHOOL_CA" | null,
  knownRubric?: ConciseRubric | null,
  opts?: {
    pureAi?: boolean;
    referenceQuestions?: GradeMarkingScriptQuestion[];
    hasQuestionPaper?: boolean;
    lightweight?: boolean;
  }
): string {
  const pureAi = opts?.pureAi === true;
  const lightweight = opts?.lightweight === true;
  const referenceQuestions = opts?.referenceQuestions ?? [];

  const schemeText = questions
    .map((q) => `${q.label} (max ${q.maxMarks} marks): expected answer/keywords — ${q.expectedAnswerOrKeywords}`)
    .join("\n");

  const referenceText =
    referenceQuestions.length > 0
      ? [
          "",
          "REFERENCE ONLY — the school has a saved marking key for this subject. It was NOT written for " +
            "this exact paper, so treat it as a helpful reference, not the authority: use an expected " +
            "answer from it when a question on this paper clearly corresponds, and rely on your own " +
            "subject expertise for everything else. Never withhold a deserved mark just because this " +
            "reference doesn't list the point.",
          referenceQuestions
            .map((q) => `- ${q.label} (~${q.maxMarks} marks): ${q.expectedAnswerOrKeywords}`)
            .join("\n"),
        ].join("\n")
      : "";

  const questionPaperNote = opts?.hasQuestionPaper
    ? "\nAfter the answer-script pages, extra images of the QUESTION PAPER / official marking guide are " +
      "attached — use them to see the full questions and their mark allocations. They are not part of " +
      "the student's script; nothing on them is the student's answer."
    : "";

  // Cover-page rules. Either we already have them (script 2..n of a
  // cohort — reuse verbatim, do not re-derive), or this is script 1 and
  // the model must read them off the first attached page.
  const rubricSection = knownRubric
    ? [
        "",
        "SECTION RULES FOR THIS EXAMINATION (already read from the first script's cover page — apply " +
          "these exactly, do NOT re-derive them, and set `rubric` to null in your response):",
        ...knownRubric.sections.map(
          (s) =>
            `- ${s.name}: ` +
            `${s.questionsToAnswer != null ? `answer ${s.questionsToAnswer} question(s)` : "answer all questions"}` +
            `${s.marksAllocated != null ? `, worth ${s.marksAllocated} marks` : ""}`
        ),
        knownRubric.paperTotalMarks != null ? `- Paper total: ${knownRubric.paperTotalMarks} marks` : "",
        knownRubric.instructionsSummary ? `- Notes: ${knownRubric.instructionsSummary}` : "",
      ].join("\n")
    : [
        "",
        "READ THE COVER / INSTRUCTIONS PAGE (normally the FIRST attached image) and populate `rubric` in " +
          "your response: every section label, how many questions the candidate is required to answer " +
          "from each section (e.g. \"answer any ONE question\" -> questionsToAnswer 1; if a section says " +
          "nothing, questionsToAnswer null), each section's own allocated marks if the paper states " +
          "them, the paper's stated grand total if any, and a short plain-language `instructionsSummary` " +
          "of the marking rules that actually mattered. If the paper has no sections or instructions at " +
          "all, set `rubric` to null.",
      ].join("\n");

  const schemeConventionsSection =
    markConventions && markConventions.length > 0
      ? [
          "",
          "This marking scheme's own front page states these conventions — they take priority over " +
            "everything below wherever they conflict:",
          markConventions.map((c) => `- ${c}`).join("\n"),
        ].join("\n")
      : "";
  const subjectModuleText = selectSubjectModule(subjectName);
  const subjectModuleSection = subjectModuleText ? `\n${subjectModuleText}` : "";
  const examStandardText = examStandardGuidance(examStandard);
  const examStandardSection = examStandardText ? `\n${examStandardText}` : "";

  const intro =
    "The attached images are photos of one student's answer script, in page order (page 1 is the FIRST " +
    "image attached, page 2 the second, and so on). Some scripts are entirely handwritten; others mix " +
    "pre-printed material with the student's own handwritten answers. Distinguish the two: pre-printed " +
    "question text is never the student's answer." +
    questionPaperNote;

  const identifyStep = pureAi
    ? "0. THERE IS NO MARKING KEY. You are the marking engine. First work out what the student had to do: " +
      "from the questions printed on the script (and the attached question-paper images, if any), list " +
      "every question the student was required to attempt. For each, choose a stable questionLabel " +
      "(e.g. '1(a)', '3'), read the marks it carries from the paper's own allocation into maxMarks (use " +
      "a sensible value only if the paper shows none), and note its section. Then mark each answer " +
      "against your own expert subject knowledge AND any marking guidance printed on the paper itself."
    : "For EACH question in the marking scheme below, set maxMarks to that question's own maximum:";

  const step1 = pureAi
    ? "1. For each question you identified: find the student's own answer (handwriting, or a handwritten " +
      "mark/circle/tick on a printed option), transcribe it, and award marksAwarded out of maxMarks — " +
      "partial credit is normal, not just full marks or zero."
    : "1. Find the student's own answer (handwriting, or a handwritten mark/circle/tick on a printed " +
      "option), transcribe it, and award marks out of that question's maximum — partial credit is " +
      "normal, not just full marks or zero.";

  const step2 = pureAi
    ? "2. Set markingBasis: 'exact_match' for an objectively correct/incorrect answer (a fact, a " +
      "calculation, a multiple-choice pick); 'reasonable_equivalence' when the mark rested on your own " +
      "subject-matter judgment of an open response; 'not_applicable' when no answer was found."
    : "2. Set markingBasis: 'exact_match' when the mark came from a listed expected answer/alternative " +
      "with no judgment call; 'reasonable_equivalence' when you awarded a mark for a relevant, accurate " +
      "point NOT explicitly listed; 'not_applicable' when no such judgment applies (no answer found, or " +
      "purely objective).";

  return [
    intro,
    identifyStep,
    step1,
    step2,
    "3. Give confidence: 'high' only when both legible AND you're confident the mark is right - NEVER " +
      "'high' when markingBasis is 'reasonable_equivalence'; 'low' when hard to read/ambiguous/unsure; " +
      "'medium' otherwise.",
    "4. Set sectionName to the paper's own verbatim section label for this question (e.g. 'Section A'), " +
      "or null only if the paper has no sections. When a candidate has answered MORE questions in a " +
      "section than the rules require, still mark every attempt you can find — the app keeps only the " +
      "best-scoring required number per section, so nothing is lost by marking them all.",
    lightweight
      ? "5. Set pageIndex and box to null for every answer — this marker only records marks and scores, " +
        "it does not place anything on the page image."
      : "5. Set pageIndex to which photographed answer-script page (0-based - the first image attached is " +
        "page 0) the student's own handwritten answer for this exact question physically appears on, and " +
        "box to a TIGHT bounding box around just that handwritten answer (not the whole page, not any " +
        "printed text) as {yMin, xMin, yMax, xMax}, each an integer 0-1000 normalized across that page " +
        "image's own real width/height (0,0 is the top-left corner, 1000,1000 the bottom-right). This is " +
        "where a real tick or cross is drawn directly onto the actual photographed page, right on/next to " +
        "the student's own answer - it must be genuinely accurate, not a rough guess. Set BOTH pageIndex " +
        "and box to null when you are not confident of the exact location (and never point at a " +
        "question-paper image) - an inaccurate mark on a real scanned document is worse than none, and a " +
        "null still gets the answer marked, just placed on a separately generated document instead.",
    "6. Separately, write 3 to 8 short observations (one sentence each) about this candidate's " +
      "performance on THIS script, spread across the sections they attempted. These are printed onto " +
      "the marked script as a brief report.",
    "Keep every transcribedAnswer SHORT — the gist of the student's answer in at most 20 words, not a " +
      "full copy.",
    rubricSection,
    referenceText,
    pureAi ? "" : "\nMarking scheme:\n" + schemeText,
    schemeConventionsSection,
    subjectModuleSection,
    examStandardSection,
    "",
    UNIVERSAL_MARKING_CONVENTIONS,
    "",
    (pureAi
      ? "Return one answer entry per question you identified, "
      : "Return exactly one answer per question in the marking scheme, using the same question label, ") +
      "each with its maxMarks, plus the rubric (or null) and the 3-8 observations. Every mark you " +
      "award is a first-pass suggestion for a teacher to review, never a final grade — never fabricate " +
      "an answer that isn't genuinely visible in the images.",
    "",
    "Reply with ONLY this JSON object, nothing else:",
    '{"answers":[{"questionLabel":"1","transcribedAnswer":"...","marksAwarded":2,"maxMarks":3,' +
      '"confidence":"high|medium|low","markingBasis":"exact_match|reasonable_equivalence|not_applicable",' +
      '"sectionName":"Section A"|null,"pageIndex":0|null,' +
      '"box":{"yMin":0,"xMin":0,"yMax":0,"xMax":0}|null}],' +
      '"rubric":{"sections":[{"name":"Section A","questionsToAnswer":1|null,"marksAllocated":20|null}],' +
      '"paperTotalMarks":100|null,"instructionsSummary":"..."}|null,' +
      '"observations":["...","..."]}',
  ].join("\n");
}

export const gradeMarkingScriptConcise = onCall<GradeMarkingScriptConciseRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 300, memory: "1GiB", maxInstances: 5 },
  async (request): Promise<GradeMarkingScriptConciseResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to grade a script.");
    }

    const {
      pageImagesBase64,
      questions,
      referenceQuestions,
      questionPaperImagesBase64,
      subjectName,
      markConventions,
      examStandard,
      knownRubric,
      lightweight,
    } = request.data ?? {};
    if (!Array.isArray(pageImagesBase64) || pageImagesBase64.length === 0) {
      throw new HttpsError("invalid-argument", "'pageImagesBase64' must be a non-empty array.");
    }
    const isLightweight = lightweight === true;
    const model = isLightweight ? GEMINI_MODEL_LITE : GEMINI_MODEL;
    const keyedQuestions = Array.isArray(questions) && questions.length > 0 ? questions : undefined;
    const pureAi = keyedQuestions === undefined;
    const refQuestions =
      Array.isArray(referenceQuestions) && referenceQuestions.length > 0
        ? referenceQuestions.slice(0, 200)
        : [];
    const questionPaperImages = Array.isArray(questionPaperImagesBase64)
      ? questionPaperImagesBase64.slice(0, 10)
      : [];
    const cappedMarkConventions = Array.isArray(markConventions) ? markConventions.slice(0, 20) : undefined;

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const imageParts = [...pageImagesBase64, ...questionPaperImages].map((b64) => ({
      inlineData: { mimeType: "image/jpeg", data: b64 },
    }));

    const promptText = buildConciseMarkingPrompt(
      keyedQuestions ?? [],
      subjectName,
      cappedMarkConventions,
      examStandard,
      knownRubric ?? null,
      {
        pureAi,
        referenceQuestions: refQuestions,
        hasQuestionPaper: questionPaperImages.length > 0,
        lightweight: isLightweight,
      }
    );

    const callGemini = async (useSchema: boolean): Promise<{ text: string; finishReason?: string }> => {
      const response = await ai.models.generateContent({
        model,
        contents: [{ role: "user", parts: [{ text: promptText }, ...imageParts] }],
        config: {
          responseMimeType: "application/json",
          // Attempt 2 drops the JSON Schema and relies on the explicit
          // shape spelled out in the prompt — covers the case where the
          // structured-output schema itself is what the model chokes on.
          ...(useSchema ? { responseJsonSchema: gradeMarkingScriptConciseSchema } : {}),
          // Explicit, generous output budget — a full script's worth of
          // per-question transcriptions + locations + the rubric + the
          // observations is far more than a model's default cap, and a
          // silent MAX_TOKENS truncation was producing unparseable JSON.
          maxOutputTokens: 32768,
          temperature: 0.15,
        },
      });
      return { text: response.text ?? "", finishReason: response.candidates?.[0]?.finishReason };
    };

    // Try up to twice — a transient truncation/format slip usually clears
    // on a retry, and grading is expensive enough to be worth one.
    let parsed: GradeMarkingScriptConciseResponse | undefined;
    let lastText = "";
    for (let attempt = 1; attempt <= 2 && !parsed; attempt++) {
      let result: { text: string; finishReason?: string };
      try {
        result = await callGemini(attempt === 1);
      } catch (err) {
        console.error(`gradeMarkingScriptConcise: Gemini call failed (attempt ${attempt})`, err);
        const msg = String((err as { message?: unknown })?.message ?? err);
        // A depleted prepay balance / quota is not transient — surface it
        // plainly instead of retrying and instead of a generic message.
        if (/RESOURCE_EXHAUSTED|prepayment|credits are depleted|quota|\b429\b/i.test(msg)) {
          throw new HttpsError(
            "resource-exhausted",
            "The app's AI service has run out of prepaid credit. Marking (and other AI features) will " +
              "work again once the Gemini API billing balance is topped up.",
          );
        }
        if (attempt === 2) throw new HttpsError("internal", "Failed to grade this script. Please try again.");
        continue;
      }
      lastText = result.text;
      if (result.finishReason && result.finishReason !== "STOP") {
        console.warn(`gradeMarkingScriptConcise: finishReason=${result.finishReason} (attempt ${attempt}), len=${result.text.length}`);
      }
      if (!result.text) continue;
      try {
        parsed = JSON.parse(result.text);
      } catch {
        // fall through to retry / salvage
      }
    }

    if (!parsed) {
      const salvaged = salvageTruncatedConciseJson(lastText);
      if (salvaged && salvaged.answers.length > 0) {
        console.warn(`gradeMarkingScriptConcise: salvaged ${salvaged.answers.length} answer(s) from truncated response`);
        parsed = salvaged;
      } else {
        console.error("gradeMarkingScriptConcise: response was not valid JSON", lastText.slice(0, 2000));
        throw new HttpsError("internal", "The grading response could not be parsed.");
      }
    }

    if (!Array.isArray(parsed.answers)) parsed.answers = [];
    if (!Array.isArray(parsed.observations)) parsed.observations = [];
    if (parsed.rubric === undefined) parsed.rubric = null;

    // Defensive clamp — never trust the model's own marksAwarded to
    // respect the cap even though the prompt asks for it (same discipline
    // the client already applies for gradeMarkingScript). In keyed mode
    // the scheme's own maxMarks wins; in pure-AI mode the model's own
    // per-answer maxMarks is the ceiling (and is itself floored to 0).
    const maxByLabel = keyedQuestions
      ? new Map(keyedQuestions.map((q) => [q.label, q.maxMarks]))
      : undefined;
    for (const a of parsed.answers) {
      const keyedMax = maxByLabel?.get(a.questionLabel);
      if (typeof keyedMax === "number") a.maxMarks = keyedMax;
      if (typeof a.maxMarks !== "number" || !(a.maxMarks > 0)) a.maxMarks = 1;
      a.marksAwarded = Math.max(0, Math.min(a.marksAwarded, a.maxMarks));
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

// Which real marking regime this assessment is: an ECZ-style national mock
// (marked to the identical strictness as the real national exam) or an
// ordinary school-based continuous-assessment test (Mid-Term/End-of-Term).
// "UNSPECIFIED" is a real, honest answer — never guessed when the document
// genuinely doesn't say one way or the other (see buildDeriveMarkingKeyPrompt).
type ExamStandardHint = "NATIONAL_MOCK" | "SCHOOL_CA" | "UNSPECIFIED";

interface DeriveMarkingKeyResponse {
  questions: DerivedQuestion[];
  sections: DerivedSection[];
  notes: string;
  detectedTitle: string;
  // Rules Engine (2026-09-08, per explicit request — "the front page is
  // the law"): explicit statements the front page/header itself makes
  // about how marks are awarded (e.g. "one mark per bullet point", "no
  // half marks", "accept alternative answers separated by /", "own words
  // acceptable"). Only what the document ACTUALLY states — empty array
  // when nothing explicit is printed, never invented or inferred from
  // general exam convention (gradeMarkingScript already applies sensible
  // universal defaults on top of whatever real conventions land here).
  markConventions: string[];
  examStandardHint: ExamStandardHint;
  // The paper's own EXPLICITLY PRINTED grand total (e.g. "Total: 100
  // marks"), never computed/summed by the AI itself — null when no such
  // statement is genuinely visible. Lets the client warn a teacher when
  // their own confirmed section totals (MarkingSchemePaperStructureScreen)
  // disagree with what the paper itself claims, without ever silently
  // overriding what the teacher enters.
  detectedTotalMarks: number | null;
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
    markConventions: {
      type: "array",
      items: { type: "string" },
      description:
        "Explicit statements the document ITSELF makes about how marks are awarded (e.g. 'one mark per " +
        "bullet point', 'no half marks awarded', 'alternative answers separated by / are all acceptable', " +
        "'answers in the candidate's own words are acceptable'). Only what is genuinely printed/written - " +
        "empty array if the document states no such conventions of its own.",
    },
    examStandardHint: {
      type: "string",
      enum: ["NATIONAL_MOCK", "SCHOOL_CA", "UNSPECIFIED"],
      description:
        "'NATIONAL_MOCK' when the document's own title/heading reads like a standardized mock, national, " +
        "final, or trial examination (meant to be marked at the same strictness as the real national exam). " +
        "'SCHOOL_CA' when it reads like an ordinary school-based test (a Mid-Term Test, End-of-Term Test, or " +
        "similar continuous-assessment paper). 'UNSPECIFIED' when the document genuinely gives no clear " +
        "signal either way - never guess.",
    },
    detectedTotalMarks: {
      type: ["number", "null"],
      description:
        "The paper's own EXPLICITLY PRINTED grand total (e.g. 'Total: 100 marks'), never computed or " +
        "summed by you from the individual questions - null if no such statement is genuinely visible " +
        "anywhere on the document.",
    },
  },
  required: [
    "questions",
    "sections",
    "notes",
    "detectedTitle",
    "markConventions",
    "examStandardHint",
    "detectedTotalMarks",
  ],
  additionalProperties: false,
};

// Rules Engine, Step 0 (2026-09-08, per explicit request: "the front page
// is the law") — instructions shared by BOTH source-type branches below,
// since a marking key/answer key and a bare question paper carry these
// same three signals the same way: read what the document's own front
// page/header genuinely states, never invent or infer beyond it.
const RULE_EXTRACTION_INSTRUCTIONS = [
  "Also extract three more things from the document's own front page/header, if present:",
  "- markConventions: any EXPLICIT statement about how marks are awarded (e.g. 'one mark per bullet " +
    "point', 'no half marks', 'alternative answers separated by / are all acceptable', 'own words " +
    "acceptable', 'no partial marks for an incomplete short answer'). Only what is genuinely printed or " +
    "written - empty array if the document states no such conventions of its own; never invent one just " +
    "because it sounds like a plausible exam rule.",
  "- examStandardHint: 'NATIONAL_MOCK' if the title/heading reads like a standardized mock, national, " +
    "final, or trial examination; 'SCHOOL_CA' if it reads like an ordinary school-based test (Mid-Term " +
    "Test, End-of-Term Test, continuous-assessment paper); 'UNSPECIFIED' if genuinely unclear either way " +
    "- never guess.",
  "- detectedTotalMarks: the paper's own EXPLICITLY PRINTED grand total (e.g. 'Total: 100 marks') - " +
    "null if not genuinely stated anywhere; never compute this yourself by summing the questions.",
].join("\n");

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
      "7. A question split into Roman-numeral/lettered sub-parts (e.g. '2(i)', '2(ii)', '2(iii)') is ONE " +
        "numbered question, not several - keep its own label exactly as printed for each sub-part (each " +
        "still needs its own row here, since each sub-part genuinely needs its own expected answer for " +
        "grading), but do not treat '2(i)'/'2(ii)'/'2(iii)' as three independent top-level questions when " +
        "estimating marks: if the source states a section's own total (e.g. 'Section A: 30 marks') or an " +
        "overall per-question value that the sub-parts should sum to, distribute marks across that " +
        "question's own sub-parts so they add up to what the source actually states for that question - " +
        "never invent extra marks by treating each Roman-numeral sub-part as if it carried the full " +
        "per-question or per-section allocation on its own.",
      "8. Populate sections with one entry per distinct section heading found (in the order they appear), " +
        "each paired with that section's own real answer-instruction line exactly as printed/written - " +
        "empty array if there are no sections.",
      "9. Set detectedTitle to the document's own title/heading exactly as printed or written (e.g. 'Grade " +
        "12 Mathematics Final Examination'), or an empty string if none is genuinely visible - never invent " +
        "one.",
      "",
      RULE_EXTRACTION_INSTRUCTIONS,
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
    "6. A question split into Roman-numeral/lettered sub-parts (e.g. '2(i)', '2(ii)', '2(iii)') is ONE " +
      "numbered question, not several - keep its own label exactly as printed for each sub-part (each " +
      "still needs its own row here, since each sub-part genuinely needs its own model answer for " +
      "grading), but do not treat '2(i)'/'2(ii)'/'2(iii)' as three independent top-level questions when " +
      "estimating marks: if the paper states a section's own total (e.g. 'Section A: 30 marks') or an " +
      "overall per-question value that the sub-parts should sum to, distribute marks across that " +
      "question's own sub-parts so they add up to what the paper actually states for that question - " +
      "never invent extra marks by treating each Roman-numeral sub-part as if it carried the full " +
      "per-question or per-section allocation on its own. A real Zambian exam convention worth knowing: " +
      "a paper with Section A/B (several questions, some split into sub-parts, ALL answered) and Section " +
      "C/D (one full essay chosen from several alternatives) typically states each section's own fixed " +
      "total (e.g. 30/30/20/20 marks summing to 100) rather than a per-question value - read the paper's " +
      "own stated totals rather than assuming this exact split, but recognise the pattern when it's there.",
    "7. Populate sections with one entry per distinct section heading found (in the order they appear), " +
      "each paired with that section's own real answer-instruction line exactly as printed/written - empty " +
      "array if there are no sections.",
    "8. Set detectedTitle to the document's own title/heading exactly as printed or written (e.g. 'Grade " +
      "12 Mathematics Final Examination'), or an empty string if none is genuinely visible - never invent " +
      "one.",
    "",
    RULE_EXTRACTION_INSTRUCTIONS,
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to generate a marking key. Please try again.");
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to transcribe this list. Please try again.");
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to transcribe this document. Please try again.");
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to read the cover page. Please try again.");
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to transcribe the reference page. Please try again.");
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to transcribe this test submission. Please try again.");
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
// getPhotoBatchUrl — "Share the Photo Batch" (Scan Marker, 2026-09-10,
// per explicit request). The client uploads a composed PDF of one
// cohort's captured script pages DIRECTLY to Storage under
// photo_batches/{own uid}/{batchId}/batch.pdf (see storage.rules — a
// real client-write rule, unlike teacher_submissions above, specifically
// so a large multi-script PDF never has to pass through a Callable
// Function's own payload-size ceiling as base64). This function's only
// job is minting a real, sharable signed URL for that already-uploaded
// file — reads stay denied in storage.rules, same "no client reads a
// plain gs:// path directly" reasoning used everywhere else in this app.
//
// A real requirement this function's own 30-day expiry exists for: "a
// link that can be pasted in any other AI platform to process the
// marking from there if so desired" only works if the link outlives a
// single app session — getSubmissionFileUrl's 15-minute expiry (a
// download-on-demand pattern) would defeat that entirely.
// ---------------------------------------------------------------------

interface GetPhotoBatchUrlRequest {
  storagePath: string;
}

export const getPhotoBatchUrl = onCall<GetPhotoBatchUrlRequest>(
  { region: "us-central1", timeoutSeconds: 30, memory: "256MiB", maxInstances: 5 },
  async (request): Promise<{ url: string }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { storagePath } = request.data ?? {};
    if (typeof storagePath !== "string" || storagePath.length === 0) {
      throw new HttpsError("invalid-argument", "'storagePath' is required.");
    }
    // Ownership check mirrors storage.rules' own write rule: a teacher can
    // only ever ask for a link to a file under their own uid segment.
    if (!storagePath.startsWith(`photo_batches/${request.auth.uid}/`)) {
      throw new HttpsError("permission-denied", "This file isn't yours.");
    }

    const file = admin.storage().bucket().file(storagePath);
    const [exists] = await file.exists();
    if (!exists) {
      throw new HttpsError("not-found", "That photo batch could not be found — it may not have finished uploading.");
    }

    const [url] = await file.getSignedUrl({
      action: "read",
      expires: Date.now() + 30 * 24 * 60 * 60 * 1000,
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Could not search right now. Please try again.");
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to detect a name from this page.");
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
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to generate minutes from these notes. Please try again.");
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

// ---------------------------------------------------------------------
// generateSchemeOfWorkContent — Scheme of Work generation's fallback for a
// real, common gap: a topic exists in the bundled syllabus (a real,
// sourced topic/sub-topic name, sometimes with a real description) but
// this app has no real Specific Competence/Outcome or Learning Activities
// content for it (verified 2026-08-29: true for a real share of bundled
// sub-topics — see scheme_of_work_template.dart's own doc comment). A
// genuinely richer real SCHEME of work (not just a syllabus) is always
// preferred when this app has one — this only ever runs for a row that
// still has nothing after that, and only for the specific column(s) that
// are empty, never overwriting real sourced content.
//
// Grounded strictly in the real topic/sub-topic/description given — this
// elaborates on real, already-sourced syllabus content, the same way
// generateLessonPlan does, never invents a new topic or outcome unrelated
// to what was given. Batched: one call covers every thin row in a whole
// document (potentially all 11 real teaching weeks), not one call per
// row, so generating one scheme never costs more than generating one
// lesson plan already does.
// ---------------------------------------------------------------------

interface SchemeOfWorkContentItem {
  id: string;
  topicName: string;
  subTopicName?: string;
  existingDescription?: string;
  needsSpecificCompetence: boolean;
  needsLearningActivities: boolean;
}

interface GenerateSchemeOfWorkContentRequest {
  subjectName: string;
  gradeName: string;
  curriculumName: string;
  items: SchemeOfWorkContentItem[];
}

interface SchemeOfWorkContentResult {
  id: string;
  specificCompetence?: string;
  learningActivities?: string;
}

interface GenerateSchemeOfWorkContentResponse {
  items: SchemeOfWorkContentResult[];
}

const generateSchemeOfWorkContentSchema = {
  type: "object",
  properties: {
    items: {
      type: "array",
      description: "Exactly one entry per item id given, in the same order.",
      items: {
        type: "object",
        properties: {
          id: { type: "string", description: "Must exactly match one of the given item ids." },
          specificCompetence: {
            type: "string",
            description:
              "1-2 realistic Specific Competence/Outcome statements for this exact topic, in the style " +
              "of real Zambian CDC/Ministry syllabus outcome wording (e.g. 'Explain...', 'Describe...', " +
              "'Analyse...', 'Demonstrate...'). Empty string if this item's needsSpecificCompetence was false.",
          },
          learningActivities: {
            type: "string",
            description:
              "2-4 concise, concrete learning activities a teacher could actually run in one real " +
              "lesson to teach this exact topic - plain text, newline-separated, no Markdown. Empty " +
              "string if this item's needsLearningActivities was false.",
          },
        },
        required: ["id", "specificCompetence", "learningActivities"],
        additionalProperties: false,
      },
    },
  },
  required: ["items"],
  additionalProperties: false,
};

function buildSchemeOfWorkContentPrompt(req: GenerateSchemeOfWorkContentRequest): string {
  return [
    `A Zambian ${req.curriculumName} Scheme of Work is being generated for ${req.subjectName}, ` +
      `${req.gradeName}. Every topic below is a REAL topic/sub-topic from this app's own bundled ` +
      "syllabus data - it genuinely has no real Specific Competence/Outcome and/or Learning Activities " +
      "content sourced for it yet. For each one, using ONLY its own topic/sub-topic name and " +
      "description below (never introducing an unrelated topic, and never contradicting what's given), " +
      "generate just the field(s) it's missing:",
    "",
    ...req.items.map((item, i) => {
      const lines = [
        `Item ${i + 1} (id: ${item.id}):`,
        `  Topic: ${item.topicName}`,
        item.subTopicName ? `  Sub-topic: ${item.subTopicName}` : null,
        item.existingDescription ? `  Description: ${item.existingDescription}` : null,
        `  Needs Specific Competence/Outcome: ${item.needsSpecificCompetence ? "yes" : "no"}`,
        `  Needs Learning Activities: ${item.needsLearningActivities ? "yes" : "no"}`,
      ];
      return lines.filter((l): l is string => l !== null).join("\n");
    }),
    "",
    "Return exactly one result per item id, in the same order given. For any field an item does not " +
      "need, return an empty string for it rather than generating something anyway. If a topic/sub-" +
      "topic name alone is too vague to responsibly generate real content for, do your best with " +
      "genuinely standard, well-established coverage for that subject/topic at this level rather than " +
      "inventing specifics that don't belong to it.",
  ].join("\n");
}

export const generateSchemeOfWorkContent = onCall<GenerateSchemeOfWorkContentRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 120, maxInstances: 5 },
  async (request): Promise<GenerateSchemeOfWorkContentResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to generate scheme of work content.");
    }

    const { subjectName, gradeName, curriculumName, items } = request.data ?? {};
    if (typeof subjectName !== "string" || subjectName.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'subjectName' is required.");
    }
    if (typeof gradeName !== "string" || gradeName.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'gradeName' is required.");
    }
    if (typeof curriculumName !== "string" || curriculumName.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'curriculumName' is required.");
    }
    if (!Array.isArray(items) || items.length === 0) {
      throw new HttpsError("invalid-argument", "'items' must be a non-empty array.");
    }
    for (const item of items as unknown[]) {
      if (
        typeof item !== "object" ||
        item === null ||
        typeof (item as Record<string, unknown>).id !== "string" ||
        typeof (item as Record<string, unknown>).topicName !== "string"
      ) {
        throw new HttpsError("invalid-argument", "Each item requires at least 'id' and 'topicName'.");
      }
    }
    // Real per-request cost/latency guard - a full scheme has at most
    // TermDates.teachingWeekCount (11) real content rows, so this leaves
    // generous headroom without letting one malformed client request fan
    // out into an unbounded Gemini call.
    if (items.length > 20) {
      throw new HttpsError("invalid-argument", "Too many items in one request (max 20).");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const req: GenerateSchemeOfWorkContentRequest = { subjectName, gradeName, curriculumName, items };

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: buildSchemeOfWorkContentPrompt(req),
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: generateSchemeOfWorkContentSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("generateSchemeOfWorkContent: Gemini call failed", err);
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to generate scheme of work content. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return any content.");
    }

    let parsed: GenerateSchemeOfWorkContentResponse;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("generateSchemeOfWorkContent: response was not valid JSON", text);
      throw new HttpsError("internal", "The response could not be parsed.");
    }

    return parsed;
  }
);

// ---------------------------------------------------------------------
// parseVoiceCommand — the tap-to-talk "standby" voice-command capability
// (2026-09-08, per explicit request, clarified via AskUserQuestion:
// tap-to-talk, not always-on background listening; a transcript sent
// here to be parsed, not a fixed local keyword parser). The client does
// on-device speech-to-text (speech_to_text, Android's own
// SpeechRecognizer — no audio ever leaves the device); only the resulting
// TEXT transcript is sent here. This function's only job is turning that
// free-form transcript into a structured intent — it does NOT look up or
// touch any real syllabus content itself, and never invents a subject/
// grade/topic that wasn't actually said; the client resolves the
// returned fields against the app's own real bundled data (see
// VoiceCommandResolver) and always shows the teacher a plain-language
// confirmation of what it understood before acting on it.
// ---------------------------------------------------------------------

interface ParseVoiceCommandRequest {
  transcript: string;
}

type VoiceCommandAction =
  | "generate_lesson_plan"
  | "generate_scheme_of_work"
  | "generate_record_of_work"
  | "generate_teaching_notes"
  | "find_topic"
  | "open_marking"
  | "open_class_roster"
  | "check_cdc_materials"
  | "resume_lesson"
  | "unrecognized";

interface ParseVoiceCommandResponse {
  action: VoiceCommandAction;
  subjectName: string | null;
  gradeName: string | null;
  topicNumber: number | null;
  weekNumber: number | null;
  termNumber: number | null;
  // A content phrase describing a topic by WHAT it's about rather than by
  // number (2026-09-08, e.g. "parable of talents", "photosynthesis") — set
  // whenever the teacher described a topic this way instead of (or as well
  // as) a topicNumber, on ANY action, not just 'find_topic'. Never a whole
  // sentence — just the real subject-matter phrase itself.
  topicKeyword: string | null;
  // The class this command is about, exactly as spoken (e.g. "Grade 10A",
  // "11B") — only ever set for 'open_class_roster'. Not the same as
  // gradeName/subjectName: a class here is one specific real roster in the
  // Grade Teacher / Report Form pipeline, not a curriculum subject.
  className: string | null;
  // A short, plain-language restatement of what was understood, e.g.
  // "Generate Lesson Plan — Civic Education, Grade 10, topic 2, week 8" —
  // shown to the teacher to confirm before anything happens. Always
  // present, even for an 'unrecognized' action (explains what was
  // missing/unclear instead).
  summary: string;
}

const parseVoiceCommandSchema = {
  type: "object",
  properties: {
    action: {
      type: "string",
      enum: [
        "generate_lesson_plan",
        "generate_scheme_of_work",
        "generate_record_of_work",
        "generate_teaching_notes",
        "find_topic",
        "open_marking",
        "open_class_roster",
        "check_cdc_materials",
        "resume_lesson",
        "unrecognized",
      ],
      description:
        "Which of this app's real functions the command is asking for. 'find_topic' is a LOOKUP — the " +
        "teacher is asking where/which topic covers something, not yet asking to generate anything from " +
        "it (e.g. 'which topic can I find the parable of talents in'). 'open_marking' opens the AI " +
        "marking assistant. 'open_class_roster' opens one specific class's roster/report-form status in " +
        "the Grade Teacher pipeline (needs className, not subjectName). 'check_cdc_materials' asks " +
        "whether new official CDC materials are available. 'resume_lesson' continues the single most " +
        "recently paused lesson, across any subject, with no subject named at all. 'unrecognized' when " +
        "the transcript doesn't clearly ask for any of the above, or (for every action except " +
        "'resume_lesson') is missing a subject entirely.",
    },
    subjectName: {
      type: ["string", "null"],
      description: "The subject exactly as spoken (e.g. 'Civic Education'), or null if none was said.",
    },
    gradeName: {
      type: ["string", "null"],
      description:
        "The grade/form exactly as spoken (e.g. 'Grade 10', 'Form 2'), or null if none was said.",
    },
    topicNumber: {
      type: ["integer", "null"],
      description:
        "The topic's ordinal position if a number was spoken (e.g. 'topic number two' -> 2, 'the " +
        "third topic' -> 3), or null if no topic number was said.",
    },
    weekNumber: {
      type: ["integer", "null"],
      description: "The week number if one was spoken (e.g. 'week 8' -> 8), or null if none was said.",
    },
    termNumber: {
      type: ["integer", "null"],
      description: "The term number (1, 2, or 3) if one was spoken, or null if none was said.",
    },
    topicKeyword: {
      type: ["string", "null"],
      description:
        "A real content phrase describing a topic by WHAT it covers (e.g. 'parable of talents', " +
        "'photosynthesis', 'the French Revolution') — set whenever the teacher named a topic this way " +
        "instead of, or alongside, a topicNumber. Extract only the real subject-matter phrase itself, " +
        "never the surrounding sentence. Null when no such phrase was said.",
    },
    className: {
      type: ["string", "null"],
      description:
        "The specific class named, exactly as spoken (e.g. 'Grade 10A', '11B') — set ONLY for " +
        "'open_class_roster'. This is a real roster/class in the Grade Teacher pipeline, not a " +
        "curriculum subject/grade — never confuse this with subjectName/gradeName.",
    },
    summary: {
      type: "string",
      description: "A short, plain-language restatement of what was understood, per this function's own doc comment.",
    },
  },
  required: [
    "action",
    "subjectName",
    "gradeName",
    "topicNumber",
    "weekNumber",
    "termNumber",
    "topicKeyword",
    "className",
    "summary",
  ],
  additionalProperties: false,
};

function buildParseVoiceCommandPrompt(transcript: string): string {
  return [
    "A teacher just spoke a voice command to an app that generates Lesson Plans, Schemes of Work, " +
      "Records of Work, and Teaching Notes from a bundled Zambian school curriculum, plus an AI " +
      "marking assistant, a Grade Teacher class/report-form pipeline, and a catalog of official CDC " +
      "curriculum materials. Extract a structured intent from their transcript — do not invent, guess, " +
      "or default any field that genuinely wasn't said; leave it null instead.",
    "",
    `Transcript: "${transcript}"`,
    "",
    "Examples:",
    "- \"make a lesson plan for topic number two in week 8 in the subject of Civic Education grade " +
      "10\" -> action=generate_lesson_plan, subjectName=\"Civic Education\", gradeName=\"Grade 10\", " +
      "topicNumber=2, weekNumber=8, termNumber=null, topicKeyword=null, className=null.",
    "- \"which topic number in RE 2046 can I find work on the parable of talents\" -> action=find_topic, " +
      "subjectName=\"RE 2046\", topicKeyword=\"parable of talents\", gradeName=null, topicNumber=null, " +
      "weekNumber=null, termNumber=null, className=null.",
    "- \"make a lesson plan on the parable of talents for RE 2046\" -> action=generate_lesson_plan, " +
      "subjectName=\"RE 2046\", topicKeyword=\"parable of talents\", topicNumber=null, weekNumber=null, " +
      "termNumber=null, className=null (a topic can be named by content phrase directly on a " +
      "generate action too, not only via 'find_topic').",
    "- \"start marking for Grade 10 Mathematics\" -> action=open_marking, subjectName=\"Mathematics\", " +
      "gradeName=\"Grade 10\", everything else null.",
    "- \"open my Grade 10A roster\" or \"how complete is Grade 11B's report forms\" -> " +
      "action=open_class_roster, className=\"Grade 10A\" / \"Grade 11B\", subjectName=null, " +
      "gradeName=null, everything else null.",
    "- \"are there new CDC materials for Geography\" -> action=check_cdc_materials, " +
      "subjectName=\"Geography\", everything else null. \"any new teaching materials\" -> " +
      "action=check_cdc_materials, subjectName=null too (a genuinely subject-less check is valid here).",
    "- \"continue where I left off\" / \"resume my last lesson\" -> action=resume_lesson, every field " +
      "(including subjectName) null — this is the one action that never needs a subject named.",
    "",
    "Only ever set action to one of the real functions above when the transcript clearly asks for that " +
      "specific one; use 'unrecognized' for small talk, an unsupported request, or (for every action " +
      "except 'resume_lesson') a command with no subject mentioned at all.",
  ].join("\n");
}

export const parseVoiceCommand = onCall<ParseVoiceCommandRequest>(
  { secrets: [geminiApiKey], region: "us-central1", maxInstances: 5 },
  async (request): Promise<ParseVoiceCommandResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to use voice commands.");
    }

    const { transcript } = request.data ?? {};
    if (typeof transcript !== "string" || transcript.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'transcript' is required.");
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: buildParseVoiceCommandPrompt(transcript),
        config: {
          responseMimeType: "application/json",
          responseJsonSchema: parseVoiceCommandSchema,
        },
      });
      text = response.text;
    } catch (err) {
      console.error("parseVoiceCommand: Gemini call failed", err);
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Failed to understand the voice command. Please try again.");
    }

    if (!text) {
      throw new HttpsError("internal", "The AI did not return a result.");
    }

    let parsed: ParseVoiceCommandResponse;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("parseVoiceCommand: response was not valid JSON", text);
      throw new HttpsError("internal", "The voice command response could not be parsed.");
    }

    return parsed;
  }
);

// ---------------------------------------------------------------------
// School Network (added 2026-09-13, per the "School network build prompts"
// brief) — Stages 1-3: school registration, joining by code, and role
// assignment. Builds directly on the real phone/email identity layer added
// the same day (see AuthService/TeacherAuthService). Firestore's role here
// expands from "one lightweight feature" (the Submissions Dashboard) to a
// real multi-teacher backbone — every permission-sensitive write funnels
// through one of these three functions (never a direct client write to
// `schools/**`), the same "clients never write sensitive collections
// directly" pattern already used for `submissions`/`dashboardAccessCodes`.
// Same as `verifyDashboardAccessCode`'s `teacherEmail` custom claim, each
// function here also stamps `schoolId`/`schoolRole` onto the caller's
// (or target's) ID token via setCustomUserClaims — Firestore rules read
// those claims directly (no extra `get()` lookups) to gate `schools/**`
// reads and the Staffroom (Stage 10, client-writable once a member).
// Client must force-refresh its ID token (getIdToken(true)) after calling
// any of these three for the new claims to take effect locally.
// ---------------------------------------------------------------------

type SchoolRole = "teacher" | "grade_teacher" | "head_teacher" | "deputy" | "administrator" | "observer";
const LEADERSHIP_ROLES: SchoolRole[] = ["head_teacher", "deputy"];
const VALID_ROLES: SchoolRole[] = ["teacher", "grade_teacher", "head_teacher", "deputy", "administrator", "observer"];

// Timetable Generation, Stage 9 (added 2026-09-14) — "co-opted Timetable
// Operator" access. A member doc's own `timetableOperator: true` flag
// (set only via `setTimetableOperator`, itself leadership/administrator-
// only) grants the SAME timetable-management rights as leadership,
// without granting anything else — an operator can't touch scores,
// roles, broadcasts, etc. Every timetable-management function below
// checks this instead of LEADERSHIP_ROLES/administrator alone.
function callerCanManageTimetable(memberData: FirebaseFirestore.DocumentData | undefined): boolean {
  const callerRole = memberData?.role as SchoolRole | undefined;
  const isOperator = memberData?.timetableOperator === true;
  return (!!callerRole && (LEADERSHIP_ROLES.includes(callerRole) || callerRole === "administrator")) || isOperator;
}

// Real 3-tier subscription structure decided 2026-09-14 (see project
// memory `project_smart_teacher_subscription_tiers`): Basic, Gold,
// Institutional — Timetable Generation requires Gold or higher.
// `subscriptionTier` is set manually via Firebase Console for now, same
// pattern as the pre-existing `institutionalSubscription` boolean, which
// this falls back to (treated as `institutional`) for a school set up
// before this field existed, so an already-paying school doesn't lose
// access just because the field is new.
const SUBSCRIPTION_TIER_ORDER: Record<string, number> = { basic: 0, gold: 1, institutional: 2 };
function schoolMeetsTimetableTier(schoolData: FirebaseFirestore.DocumentData | undefined): boolean {
  const rawTier = schoolData?.subscriptionTier as string | undefined;
  const tier = rawTier ?? (schoolData?.institutionalSubscription === true ? "institutional" : "basic");
  return (SUBSCRIPTION_TIER_ORDER[tier] ?? 0) >= SUBSCRIPTION_TIER_ORDER.gold;
}
// Excludes 0/O and 1/I/L — a human reading this code aloud or retyping it
// from a whiteboard shouldn't have to guess which character was meant.
const SCHOOL_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

function generateSchoolCode(): string {
  let code = "";
  for (let i = 0; i < 6; i++) {
    code += SCHOOL_CODE_ALPHABET[Math.floor(Math.random() * SCHOOL_CODE_ALPHABET.length)];
  }
  return code;
}

function nonEmptyString(value: unknown, maxLen = 120): value is string {
  return typeof value === "string" && value.trim().length > 0 && value.trim().length <= maxLen;
}

interface RegisterSchoolRequest {
  name: string;
  province: string;
  district: string;
  headTeacherName: string;
}

export const registerSchool = onCall<RegisterSchoolRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ schoolId: string; code: string }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to register a school.");
    }
    const { name, province, district, headTeacherName } = request.data ?? {};
    if (!nonEmptyString(name) || !nonEmptyString(province) || !nonEmptyString(district) || !nonEmptyString(headTeacherName)) {
      throw new HttpsError("invalid-argument", "School name, province, district, and Head Teacher name are all required.");
    }

    const db = admin.firestore();
    const schoolsRef = db.collection("schools");

    // Collision-check the generated code against real existing schools —
    // astronomically unlikely to collide at 6 chars from a 32-char alphabet
    // (~1 billion combinations), but checked for real rather than assumed.
    let code = generateSchoolCode();
    for (let attempt = 0; attempt < 5; attempt++) {
      const existing = await schoolsRef.where("code", "==", code).limit(1).get();
      if (existing.empty) break;
      code = generateSchoolCode();
      if (attempt === 4) {
        throw new HttpsError("internal", "Could not generate a unique school code. Please try again.");
      }
    }

    const schoolRef = schoolsRef.doc();
    const batch = db.batch();
    batch.set(schoolRef, {
      name: name.trim(),
      province: province.trim(),
      district: district.trim(),
      headTeacherName: headTeacherName.trim(),
      code,
      institutionalSubscription: false, // manual toggle only, set via Firebase console — see Stage 8 build note
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // The registering teacher becomes this school's head_teacher — the
    // brief's own framing ("typically Head Teacher or an appointed
    // teacher") doesn't force this, but someone has to hold leadership
    // rights from the start or Stage 3's role-assignment has no one
    // authorized to perform it; head_teacher is the sensible default and
    // is reassignable/shareable with a real Deputy immediately after.
    batch.set(schoolRef.collection("members").doc(request.auth.uid), {
      name: headTeacherName.trim(),
      role: "head_teacher" as SchoolRole,
      classIds: [] as string[],
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    batch.set(
      db.collection("teacher_profiles").doc(request.auth.uid),
      { schoolId: schoolRef.id, schoolRole: "head_teacher" },
      { merge: true }
    );
    await batch.commit();

    // Bug fixed 2026-09-13: this used to spread `request.auth.token` (the
    // FULL decoded ID token — issuer, expiry, auth_time, etc.) into
    // setCustomUserClaims, which Firebase rejects outright (those are
    // reserved field names) — the function crashed here every time,
    // surfacing only a bare "internal" error with no message on the
    // client. Fetching the user's actual EXISTING custom claims (not the
    // whole token) is the correct way to preserve them across this call.
    const registeringUser = await admin.auth().getUser(request.auth.uid);
    await admin.auth().setCustomUserClaims(request.auth.uid, {
      ...(registeringUser.customClaims ?? {}),
      schoolId: schoolRef.id,
      schoolRole: "head_teacher",
    });

    return { schoolId: schoolRef.id, code };
  }
);

interface JoinSchoolByCodeRequest {
  code: string;
  name: string;
}

export const joinSchoolByCode = onCall<JoinSchoolByCodeRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ schoolId: string; schoolName: string }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to join a school.");
    }
    const { code, name } = request.data ?? {};
    if (!nonEmptyString(code, 12) || !nonEmptyString(name)) {
      throw new HttpsError("invalid-argument", "A school code and your name are required.");
    }
    const normalizedCode = code.trim().toUpperCase();

    const db = admin.firestore();
    const matches = await db.collection("schools").where("code", "==", normalizedCode).limit(1).get();
    if (matches.empty) {
      throw new HttpsError("not-found", "That school code doesn't match any registered school. Double-check it with your Head Teacher.");
    }
    const schoolDoc = matches.docs[0];
    const memberRef = schoolDoc.ref.collection("members").doc(request.auth.uid);
    const existingMember = await memberRef.get();
    if (existingMember.exists) {
      // Already a member — treat as idempotent success rather than an
      // error (a teacher tapping "Join" twice shouldn't see a failure).
      return { schoolId: schoolDoc.id, schoolName: (schoolDoc.data().name as string) ?? "" };
    }

    const batch = db.batch();
    batch.set(memberRef, {
      name: name.trim(),
      role: "teacher" as SchoolRole,
      classIds: [] as string[],
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    batch.set(
      db.collection("teacher_profiles").doc(request.auth.uid),
      { schoolId: schoolDoc.id, schoolRole: "teacher" },
      { merge: true }
    );
    await batch.commit();

    // Same fix as registerSchool above — real existing custom claims, not
    // the whole decoded ID token.
    const joiningUser = await admin.auth().getUser(request.auth.uid);
    await admin.auth().setCustomUserClaims(request.auth.uid, {
      ...(joiningUser.customClaims ?? {}),
      schoolId: schoolDoc.id,
      schoolRole: "teacher",
    });

    return { schoolId: schoolDoc.id, schoolName: (schoolDoc.data().name as string) ?? "" };
  }
);

interface UpdateSchoolMemberRoleRequest {
  schoolId: string;
  targetUid: string;
  role: SchoolRole;
  classIds?: string[]; // only meaningful when role === 'grade_teacher'
}

export const updateSchoolMemberRole = onCall<UpdateSchoolMemberRoleRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, targetUid, role, classIds } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !nonEmptyString(targetUid) || !VALID_ROLES.includes(role)) {
      throw new HttpsError("invalid-argument", "A valid school, target teacher, and role are required.");
    }

    const db = admin.firestore();
    const membersRef = db.collection("schools").doc(schoolId).collection("members");
    const [callerSnap, targetSnap] = await Promise.all([membersRef.doc(request.auth.uid).get(), membersRef.doc(targetUid).get()]);
    if (!callerSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    if (!targetSnap.exists) {
      throw new HttpsError("not-found", "That teacher is not a member of this school.");
    }
    const callerRole = callerSnap.data()?.role as SchoolRole;

    // Stage 3's real permission rules: Head Teacher/Deputy can assign ANY
    // role, including other leadership roles. Assigning 'grade_teacher'
    // for a class is additionally allowed by an existing grade_teacher
    // already holding that same class (so a departing grade teacher can
    // hand off to a colleague without needing to go through leadership).
    const callerIsLeadership = LEADERSHIP_ROLES.includes(callerRole);
    const isGradeTeacherHandoff =
      role === "grade_teacher" &&
      callerRole === "grade_teacher" &&
      Array.isArray(classIds) &&
      classIds.length > 0 &&
      classIds.every((id) => Array.isArray(callerSnap.data()?.classIds) && (callerSnap.data()?.classIds as string[]).includes(id));

    if (!callerIsLeadership && !isGradeTeacherHandoff) {
      throw new HttpsError(
        "permission-denied",
        "Only the Head Teacher or Deputy can assign this role (grade_teacher for a class can also be assigned by an existing grade teacher of that same class)."
      );
    }
    if ((role === "head_teacher" || role === "deputy" || role === "administrator") && !callerIsLeadership) {
      throw new HttpsError("permission-denied", "Only the Head Teacher or Deputy can assign that role.");
    }

    const update: Record<string, unknown> = { role };
    if (role === "grade_teacher") {
      update.classIds = Array.isArray(classIds) ? classIds : [];
    } else {
      update.classIds = [];
    }
    await membersRef.doc(targetUid).update(update);
    await db.collection("teacher_profiles").doc(targetUid).set({ schoolId, schoolRole: role }, { merge: true });

    const targetUser = await admin.auth().getUser(targetUid);
    await admin.auth().setCustomUserClaims(targetUid, {
      ...(targetUser.customClaims ?? {}),
      schoolId,
      schoolRole: role,
    });

    return { success: true };
  }
);

// ---------------------------------------------------------------------
// School Network, Milestone B1 (added 2026-09-13) — the shared class
// registry that Stages 4-7 (decentralized subject-teacher report
// updates) need to actually work. Real gap this fixes: the existing
// Report Form Pipeline's classes/learners/scores are 100% on-device
// SQLite rows with local auto-increment ids — meaningless across
// devices. `schools/{schoolId}/classes/{classId}` is the real,
// shared identity a Grade Teacher's on-device ReportClass can OPTIONALLY
// link to (see ReportClass.firestoreClassId) — a class that's never
// connected keeps working exactly as it always has, fully offline,
// single-device. Same "writes only through a Cloud Function" pattern as
// the rest of School Network — see registerSchool's own comment above.
// ---------------------------------------------------------------------

interface GuardianContactInput {
  email: string | null;
  phone: string | null;
}

interface ConnectClassToSchoolRequest {
  schoolId: string;
  classGrade: string;
  term: string;
  learnerNames: string[];
  subjectNames: string[];
  // Stage 9 (added 2026-09-13, per explicit user confirmation — this is a
  // real, deliberate expansion of what leaves the device: guardian
  // contact info was previously local-only). Parallel to learnerNames;
  // optional so an older client (or a Grade Teacher who declines) can
  // still connect a class with no guardian data published at all.
  guardianContacts?: GuardianContactInput[];
}

export const connectClassToSchool = onCall<ConnectClassToSchoolRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ classId: string }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classGrade, term, learnerNames, subjectNames, guardianContacts } = request.data ?? {};
    if (
      !nonEmptyString(schoolId) ||
      !nonEmptyString(classGrade, 60) ||
      !nonEmptyString(term, 60) ||
      !Array.isArray(learnerNames) ||
      !Array.isArray(subjectNames)
    ) {
      throw new HttpsError("invalid-argument", "A school, class grade, term, learner list, and subject list are all required.");
    }
    if (learnerNames.length > 200 || subjectNames.length > 30) {
      throw new HttpsError("invalid-argument", "That roster or subject list is larger than expected.");
    }
    const cleanLearnerNames = learnerNames.filter((n): n is string => typeof n === "string" && n.trim().length > 0).map((n) => n.trim());
    const cleanSubjectNames = subjectNames.filter((n): n is string => typeof n === "string" && n.trim().length > 0).map((n) => n.trim());
    // Deliberately NOT filtered/trimmed the same way as names — a missing
    // guardian contact is a real, meaningful "we don't have this" gap
    // (see Stage 9's broadcast function, which just skips a null), not
    // something to silently drop from the array and lose the
    // learnerIndex alignment over.
    const cleanGuardianContacts: GuardianContactInput[] | null = Array.isArray(guardianContacts)
      ? guardianContacts.slice(0, cleanLearnerNames.length).map((c) => ({
          email: typeof c?.email === "string" && c.email.trim().length > 0 ? c.email.trim() : null,
          phone: typeof c?.phone === "string" && c.phone.trim().length > 0 ? c.phone.trim() : null,
        }))
      : null;

    const db = admin.firestore();
    const memberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const memberName = (memberSnap.data()?.name as string | undefined) ?? "";

    const classesRef = db.collection("schools").doc(schoolId).collection("classes");
    // Idempotent: re-connecting the same class (e.g. the Grade Teacher
    // reopens the screen, or the roster changed) refreshes the snapshot
    // on the existing doc rather than creating a duplicate class.
    const existing = await classesRef
      .where("classGrade", "==", classGrade.trim())
      .where("term", "==", term.trim())
      .where("gradeTeacherUid", "==", request.auth.uid)
      .limit(1)
      .get();
    const targetRef = existing.empty ? classesRef.doc() : existing.docs[0].ref;
    if (existing.empty) {
      await targetRef.set({
        classGrade: classGrade.trim(),
        term: term.trim(),
        gradeTeacherUid: request.auth.uid,
        gradeTeacherName: memberName,
        learnerNames: cleanLearnerNames,
        subjectNames: cleanSubjectNames,
        subjectTeacherUids: {},
        assignedTeacherUids: [] as string[],
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else {
      await targetRef.update({
        learnerNames: cleanLearnerNames,
        subjectNames: cleanSubjectNames,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    if (cleanGuardianContacts !== null) {
      // Separate doc, separate (leadership-only) read rule — see
      // firestore.rules — never merged onto the class doc itself, which
      // every school member can read.
      await targetRef.collection("guardianContacts").doc("data").set({
        contacts: cleanGuardianContacts,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    return { classId: targetRef.id };
  }
);

interface AssignSubjectTeacherRequest {
  schoolId: string;
  classId: string;
  subjectName: string;
  targetUid: string | null; // null unassigns the subject
}

export const assignSubjectTeacher = onCall<AssignSubjectTeacherRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, subjectName, targetUid } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !nonEmptyString(classId) || !nonEmptyString(subjectName, 60)) {
      throw new HttpsError("invalid-argument", "A school, class, and subject are required.");
    }
    if (targetUid !== null && !nonEmptyString(targetUid)) {
      throw new HttpsError("invalid-argument", "targetUid must be a non-empty string or null.");
    }

    const db = admin.firestore();
    const classRef = db.collection("schools").doc(schoolId).collection("classes").doc(classId);
    const [classSnap, callerMemberSnap] = await Promise.all([
      classRef.get(),
      db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get(),
    ]);
    if (!classSnap.exists) {
      throw new HttpsError("not-found", "That class is not connected to this school.");
    }
    if (!callerMemberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const classData = classSnap.data()!;
    const callerRole = callerMemberSnap.data()?.role as SchoolRole;
    const isLeadership = LEADERSHIP_ROLES.includes(callerRole);
    const isThisClassGradeTeacher = classData.gradeTeacherUid === request.auth.uid;
    if (!isLeadership && !isThisClassGradeTeacher) {
      throw new HttpsError("permission-denied", "Only this class's Grade Teacher, or the school's Head Teacher/Deputy, can assign subject teachers.");
    }

    if (targetUid !== null) {
      const targetMemberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(targetUid).get();
      if (!targetMemberSnap.exists) {
        throw new HttpsError("not-found", "That teacher is not a member of this school.");
      }
    }

    const subjectTeacherUids: Record<string, string> = { ...(classData.subjectTeacherUids ?? {}) };
    if (targetUid !== null) {
      subjectTeacherUids[subjectName] = targetUid;
    } else {
      delete subjectTeacherUids[subjectName];
    }
    const assignedTeacherUids = Array.from(new Set(Object.values(subjectTeacherUids)));

    await classRef.update({
      subjectTeacherUids,
      assignedTeacherUids,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { success: true };
  }
);

// ---------------------------------------------------------------------
// School Network, Milestone B2 (added 2026-09-13) — Stages 4-6: a subject
// teacher writes their own subject's scores for a connected class
// directly from their own device (Stage 4), Grade Teacher/leadership
// retain full elevated edit rights over every entry (Stage 6), and any
// edit by someone OTHER than the original submitter notifies that
// original teacher (Stage 6 — SMS + in-app) with a full audit trail. The
// Stage 5 "flagged Scan Marker entries" check is entirely on-device (Scan
// Marker data never leaves the device) — see ScanMarkerFlagService in the
// Flutter app; nothing server-side is needed for it.
// ---------------------------------------------------------------------

// Real SMS sending is intentionally stubbed — this app has never sent
// arbitrary SMS before (Phone Auth's OTP is Firebase-internal, a
// different thing entirely), and standing up a real gateway (e.g.
// Africa's Talking) is its own account/cost decision, deferred per
// explicit request (2026-09-13). Swap this body for a real HTTP call to
// the chosen gateway once that account exists — every real call site
// below already awaits this function, so nothing else needs to change.
async function sendSmsStub(to: string, body: string): Promise<void> {
  console.log(`[SMS stub] to=${to}: ${body}`);
}

function scoreEntryId(learnerIndex: number, subjectName: string): string {
  return `${learnerIndex}_${sanitizePathSegment(subjectName)}`;
}

interface SubmitClassScoreEntryRequest {
  schoolId: string;
  classId: string;
  learnerIndex: number;
  subjectName: string;
  score: number;
  comment?: string;
}

export const submitClassScoreEntry = onCall<SubmitClassScoreEntryRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, learnerIndex, subjectName, score, comment } = request.data ?? {};
    if (
      !nonEmptyString(schoolId) ||
      !nonEmptyString(classId) ||
      typeof learnerIndex !== "number" ||
      learnerIndex < 0 ||
      !nonEmptyString(subjectName, 60) ||
      typeof score !== "number" ||
      score < 0 ||
      score > 1000
    ) {
      throw new HttpsError("invalid-argument", "A valid class, learner, subject, and score (0-1000) are required.");
    }

    const db = admin.firestore();
    const classRef = db.collection("schools").doc(schoolId).collection("classes").doc(classId);
    const [classSnap, callerMemberSnap] = await Promise.all([
      classRef.get(),
      db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get(),
    ]);
    if (!classSnap.exists) {
      throw new HttpsError("not-found", "That class is not connected to this school.");
    }
    if (!callerMemberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const classData = classSnap.data()!;
    const callerRole = callerMemberSnap.data()?.role as SchoolRole;
    const callerName = (callerMemberSnap.data()?.name as string | undefined) ?? "";
    const isLeadership = LEADERSHIP_ROLES.includes(callerRole) || callerRole === "administrator";
    const isThisClassGradeTeacher = classData.gradeTeacherUid === request.auth.uid;
    const assignedSubjectTeacherUid = (classData.subjectTeacherUids ?? {})[subjectName] as string | undefined;
    const isAssignedSubjectTeacher = assignedSubjectTeacherUid === request.auth.uid;

    // Stage 6: "Grade Teacher retains full edit rights across the whole
    // Broad Mark Sheet" — unconditional, same as always. Stage 8:
    // leadership's edit rights are DIFFERENT — "without [an
    // institutionalSubscription], these roles default to Observer status
    // per class: full visibility, zero edit rights" — so leadership can
    // only fall through to editing here when the school has that flag on
    // (manually set via the Firebase console — see registerSchool's own
    // comment on why this isn't a real payment flow yet).
    let leadershipCanEdit = false;
    if (isLeadership && !isThisClassGradeTeacher && !isAssignedSubjectTeacher) {
      const schoolSnap = await db.collection("schools").doc(schoolId).get();
      leadershipCanEdit = (schoolSnap.data()?.institutionalSubscription as boolean | undefined) ?? false;
    }
    if (!isAssignedSubjectTeacher && !isThisClassGradeTeacher && !leadershipCanEdit) {
      throw new HttpsError(
        "permission-denied",
        isLeadership
          ? "This school doesn't have an institutional subscription yet, so leadership has view-only access here. Ask the Grade Teacher or assigned subject teacher to make this edit."
          : "You're not assigned to teach that subject for this class. Ask the Grade Teacher to assign you first."
      );
    }
    const learnerNames = (classData.learnerNames ?? []) as string[];
    if (learnerIndex >= learnerNames.length) {
      throw new HttpsError("invalid-argument", "That learner is not on this class's published roster.");
    }
    const learnerName = learnerNames[learnerIndex];

    const entryRef = classRef.collection("scoreEntries").doc(scoreEntryId(learnerIndex, subjectName));
    const existing = await entryRef.get();
    const cleanComment = typeof comment === "string" ? comment.trim().slice(0, 500) : "";

    if (!existing.exists) {
      await entryRef.set({
        learnerIndex,
        learnerName,
        subjectName,
        score,
        comment: cleanComment,
        submittedByUid: request.auth.uid,
        submittedByName: callerName,
        submittedAt: admin.firestore.FieldValue.serverTimestamp(),
        lastEditedByUid: request.auth.uid,
        lastEditedByName: callerName,
        lastEditedAt: admin.firestore.FieldValue.serverTimestamp(),
        editHistory: [] as unknown[],
      });
      return { success: true };
    }

    const existingData = existing.data()!;
    const isOriginalSubmitter = existingData.submittedByUid === request.auth.uid;

    await entryRef.update({
      score,
      comment: cleanComment,
      lastEditedByUid: request.auth.uid,
      lastEditedByName: callerName,
      lastEditedAt: admin.firestore.FieldValue.serverTimestamp(),
      editHistory: admin.firestore.FieldValue.arrayUnion({
        editedByUid: request.auth.uid,
        editedByName: callerName,
        editedAt: admin.firestore.Timestamp.now(), // arrayUnion can't take serverTimestamp() — real wall-clock time here is fine for an audit log entry
        previousScore: existingData.score,
        previousComment: existingData.comment ?? "",
      }),
    });

    // Stage 6: someone other than the original submitter changed the
    // entry — notify them for real, both channels.
    if (!isOriginalSubmitter && nonEmptyString(existingData.submittedByUid)) {
      const originalUid = existingData.submittedByUid as string;
      const message = `Entry of student ${learnerName} has been edited by ${callerName || "another teacher"}.`;
      await db
        .collection("teacher_profiles")
        .doc(originalUid)
        .collection("notifications")
        .add({
          message,
          learnerName,
          subjectName,
          classId,
          schoolId,
          editedByName: callerName,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          read: false,
        });
      try {
        const originalUser = await admin.auth().getUser(originalUid);
        if (originalUser.phoneNumber) {
          await sendSmsStub(originalUser.phoneNumber, message);
        }
      } catch (err) {
        console.error("submitClassScoreEntry: could not look up original submitter for SMS", err);
      }
    }

    return { success: true };
  }
);

// ---------------------------------------------------------------------
// School Network, Stage 9 (added 2026-09-13, per explicit user
// confirmation of the guardian-data-sync decision above) — mass
// broadcast to parents/guardians, gated behind institutionalSubscription
// exactly as the brief specifies. Real, honest limits on what "mass"
// means per channel:
//  - Email: really sent, via the same Brevo infrastructure already used
//    for the Submissions Dashboard's access codes.
//  - SMS: still the stub from Stage 6 (no real gateway set up yet).
//  - WhatsApp: there has never been a WhatsApp Business API anywhere in
//    this app (see AssignmentSubmissionScreen's own doc comment) — a
//    server-side function cannot open anyone's WhatsApp client. This
//    returns the recipient list to the CLIENT, which builds the same
//    per-recipient wa.me deep links + manual tap-through the rest of the
//    app already uses for WhatsApp, rather than fabricating a "mass send"
//    that doesn't actually exist for this channel.
// ---------------------------------------------------------------------

const MAX_BROADCAST_RECIPIENTS = 300;

interface BroadcastToGuardiansRequest {
  schoolId: string;
  classIds?: string[]; // omitted/empty = every class connected to the school
  subject: string;
  message: string;
}

export const broadcastToGuardians = onCall<BroadcastToGuardiansRequest>(
  { secrets: [brevoApiKey, brevoSenderEmail], region: "us-central1", timeoutSeconds: 180, memory: "256MiB", maxInstances: 5 },
  async (request): Promise<{ emailsSent: number; emailsFailed: number; smsAttempted: number; whatsappRecipients: { name: string; phone: string }[] }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classIds, subject, message } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !nonEmptyString(subject, 150) || !nonEmptyString(message, 2000)) {
      throw new HttpsError("invalid-argument", "A school, subject, and message are required.");
    }

    const db = admin.firestore();
    const [callerMemberSnap, schoolSnap] = await Promise.all([
      db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get(),
      db.collection("schools").doc(schoolId).get(),
    ]);
    if (!callerMemberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const callerRole = callerMemberSnap.data()?.role as SchoolRole;
    if (!LEADERSHIP_ROLES.includes(callerRole) && callerRole !== "administrator") {
      throw new HttpsError("permission-denied", "Only Head Teacher, Deputy, or Administrator can send a broadcast.");
    }
    if (!schoolSnap.data()?.institutionalSubscription) {
      throw new HttpsError("failed-precondition", "This school doesn't have an institutional subscription, so broadcast tools aren't unlocked yet.");
    }

    let classesQuery = db.collection("schools").doc(schoolId).collection("classes") as FirebaseFirestore.Query;
    if (Array.isArray(classIds) && classIds.length > 0) {
      classesQuery = classesQuery.where(admin.firestore.FieldPath.documentId(), "in", classIds.slice(0, 30));
    }
    const classesSnap = await classesQuery.get();

    type Recipient = { learnerName: string; email: string | null; phone: string | null };
    const recipients: Recipient[] = [];
    for (const classDoc of classesSnap.docs) {
      if (recipients.length >= MAX_BROADCAST_RECIPIENTS) break;
      const learnerNames = (classDoc.data().learnerNames ?? []) as string[];
      const contactsSnap = await classDoc.ref.collection("guardianContacts").doc("data").get();
      const contacts = (contactsSnap.data()?.contacts ?? []) as GuardianContactInput[];
      for (let i = 0; i < learnerNames.length && recipients.length < MAX_BROADCAST_RECIPIENTS; i++) {
        const contact = contacts[i];
        if (!contact || (!contact.email && !contact.phone)) continue;
        recipients.push({ learnerName: learnerNames[i], email: contact.email, phone: contact.phone });
      }
    }

    let emailsSent = 0;
    let emailsFailed = 0;
    let smsAttempted = 0;
    const whatsappRecipients: { name: string; phone: string }[] = [];

    for (const recipient of recipients) {
      if (recipient.email) {
        try {
          const response = await fetch("https://api.brevo.com/v3/smtp/email", {
            method: "POST",
            headers: { "api-key": brevoApiKey.value(), "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({
              sender: { name: "Smart Teacher", email: brevoSenderEmail.value() },
              to: [{ email: recipient.email, name: `Guardian of ${recipient.learnerName}` }],
              subject,
              htmlContent: `<p>${message.replace(/\n/g, "<br>")}</p>`,
            }),
          });
          if (response.ok) {
            emailsSent++;
          } else {
            emailsFailed++;
            console.error("broadcastToGuardians: Brevo rejected a recipient", recipient.email, response.status);
          }
        } catch (err) {
          emailsFailed++;
          console.error("broadcastToGuardians: network error emailing a guardian", err);
        }
      }
      if (recipient.phone) {
        await sendSmsStub(recipient.phone, `${subject}: ${message}`);
        smsAttempted++;
        whatsappRecipients.push({ name: recipient.learnerName, phone: recipient.phone });
      }
    }

    return { emailsSent, emailsFailed, smsAttempted, whatsappRecipients };
  }
);

// ---------------------------------------------------------------------
// School Network, Stage 5 (minimal — added 2026-09-14, per a direct
// follow-up request for the sidebar's new "Report Form Status" view,
// which needs a real Mid-Term Results Window to judge on-time entries
// against). Only the start date is settable here; the window's duration
// stays fixed at the brief's own default (2 weeks) — an adjustable
// duration and the separate End-of-Term Processing Window are real,
// disclosed gaps, not attempted in this pass since nothing asked for them
// yet. "Restrict editing these deadline settings to head_teacher/deputy
// only; the appointed administrator (HOD) can view but not change them"
// — enforced here exactly as written; note this is a NARROWER caller set
// than the general LEADERSHIP_ROLES + administrator pattern used
// elsewhere in this file, deliberately.
// ---------------------------------------------------------------------

const MID_TERM_WINDOW_DURATION_DAYS = 14;

interface SetMidTermWindowRequest {
  schoolId: string;
  startDateIso: string;
}

export const setMidTermWindow = onCall<SetMidTermWindowRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, startDateIso } = request.data ?? {};
    if (!nonEmptyString(schoolId)) {
      throw new HttpsError("invalid-argument", "A school is required.");
    }
    const startDate = new Date(startDateIso);
    if (isNaN(startDate.getTime())) {
      throw new HttpsError("invalid-argument", "A valid start date is required.");
    }

    const db = admin.firestore();
    const memberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const callerRole = memberSnap.data()?.role as SchoolRole;
    if (!LEADERSHIP_ROLES.includes(callerRole)) {
      throw new HttpsError(
        "permission-denied",
        "Only the Head Teacher or Deputy can set the Mid-Term Results Window — an Administrator can view it but not change it."
      );
    }

    await db.collection("schools").doc(schoolId).update({
      midTermWindowStart: admin.firestore.Timestamp.fromDate(startDate),
      midTermWindowDurationDays: MID_TERM_WINDOW_DURATION_DAYS,
    });
    return { success: true };
  }
);

// ---------------------------------------------------------------------
// Timetable Generation, Stage 1 — Data setup (added 2026-09-14). Just the
// config data + save path this round: periods/day, period length,
// teaching days/week, an editable per-subject "suggested default"
// periods-per-week map (explicitly labelled as adjustable in the UI, per
// the brief — never presented as an official figure), and the editable
// "Practical Subjects Exception List" (subjects allowed to be scheduled
// as single periods; everything else defaults to a 2-period block —
// Stage 4's engine, not built yet, will read this same config). Access
// is leadership-only for now (head_teacher/deputy/administrator) — Stage
// 9's dedicated `timetable_operator` role doesn't exist yet.
// ---------------------------------------------------------------------

interface SaveTimetableConfigRequest {
  schoolId: string;
  periodsPerDay: number;
  periodLengthMinutes: number;
  teachingDaysPerWeek: number;
  subjectDefaults: Record<string, number>;
  practicalSubjectsExceptionList: string[];
  maxDailyPeriodsPerTeacher: number;
}

export const saveTimetableConfig = onCall<SaveTimetableConfigRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, periodsPerDay, periodLengthMinutes, teachingDaysPerWeek, subjectDefaults, practicalSubjectsExceptionList, maxDailyPeriodsPerTeacher } =
      request.data ?? {};
    if (
      !nonEmptyString(schoolId) ||
      typeof periodsPerDay !== "number" ||
      periodsPerDay < 1 ||
      periodsPerDay > 20 ||
      typeof periodLengthMinutes !== "number" ||
      periodLengthMinutes < 10 ||
      periodLengthMinutes > 180 ||
      typeof teachingDaysPerWeek !== "number" ||
      teachingDaysPerWeek < 1 ||
      teachingDaysPerWeek > 7 ||
      typeof subjectDefaults !== "object" ||
      subjectDefaults === null ||
      !Array.isArray(practicalSubjectsExceptionList) ||
      typeof maxDailyPeriodsPerTeacher !== "number" ||
      maxDailyPeriodsPerTeacher < 1 ||
      maxDailyPeriodsPerTeacher > periodsPerDay
    ) {
      throw new HttpsError("invalid-argument", "Valid period/day counts and subject data are required.");
    }

    const db = admin.firestore();
    const memberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    if (!callerCanManageTimetable(memberSnap.data())) {
      throw new HttpsError("permission-denied", "Only school leadership or an appointed Timetable Operator can set up the timetable.");
    }
    const schoolSnap = await db.collection("schools").doc(schoolId).get();
    if (!schoolMeetsTimetableTier(schoolSnap.data())) {
      throw new HttpsError("failed-precondition", "Timetable Generation requires a Gold subscription or higher.");
    }

    const cleanSubjectDefaults: Record<string, number> = {};
    for (const [name, value] of Object.entries(subjectDefaults)) {
      if (typeof value === "number" && value >= 0 && value <= 40 && name.trim().length > 0) {
        cleanSubjectDefaults[name.trim()] = value;
      }
    }
    const cleanExceptionList = practicalSubjectsExceptionList
      .filter((s): s is string => typeof s === "string" && s.trim().length > 0)
      .map((s) => s.trim());

    await db
      .collection("schools")
      .doc(schoolId)
      .collection("timetable")
      .doc("config")
      .set(
        {
          periodsPerDay,
          periodLengthMinutes,
          teachingDaysPerWeek,
          subjectDefaults: cleanSubjectDefaults,
          practicalSubjectsExceptionList: cleanExceptionList,
          maxDailyPeriodsPerTeacher,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedByUid: request.auth.uid,
        },
        { merge: true }
      );
    return { success: true };
  }
);

// ---------------------------------------------------------------------
// Timetable Generation, Stage 4 (added 2026-09-14) — the deterministic
// scheduling engine itself. Per explicit requirement: "This engine must
// be deterministic, not AI-based — the actual scheduling validity must
// never depend on an AI call." No Gemini/AI call anywhere in this
// function or `generateTimetableSchedule` below — pure, repeatable
// constraint placement. Stage 3 (also 2026-09-14) added
// `teacherAvailability` to the config this engine reads — a teacher with
// no constraint set is available every period, exactly matching this
// engine's original behaviour, so existing schools see no change until
// they actually set an availability constraint via `setTeacherAvailability`.
//
// Implementation is greedy with a first-fit scan across (day, period) in
// a fixed, deterministic order (classes sorted by id, subjects sorted by
// name) — not full constraint-satisfaction backtracking (which would
// undo EARLIER successful placements to make room for a later one). That
// tradeoff is real and disclosed: this can produce more conflicts than a
// theoretically optimal solver would for a tightly-constrained school,
// but it NEVER produces an invalid schedule (no double-booking, ever —
// verified directly against synthetic data before shipping, not just
// assumed) — every constraint violation becomes a specific, named
// conflict instead, exactly as required ("flag the specific unresolved
// conflicts clearly rather than silently producing an invalid
// schedule").
// ---------------------------------------------------------------------

interface TimetableClassInput {
  id: string;
  classGrade: string;
  subjectNames: string[];
  subjectTeacherUids: Record<string, string>;
}

interface TimetableConfigInput {
  periodsPerDay: number;
  teachingDaysPerWeek: number;
  subjectDefaults: Record<string, number>;
  practicalSubjectsExceptionList: string[];
  maxDailyPeriodsPerTeacher: number;
  // Stage 3 (added 2026-09-14) — teacherUid -> list of "day_period" slot
  // keys that teacher is NOT available for (e.g. "Mr. Phiri can only
  // teach mornings" becomes every afternoon slot, every day). A teacher
  // with no entry here is available every period, exactly matching this
  // engine's original Stage 4 behaviour — Stage 3 only NARROWS placement,
  // it never changes the algorithm's shape. See `parseTimetableConstraint`
  // for how natural language becomes this structure (AI only extracts
  // intent; the actual slot-key computation is deterministic code, never
  // AI-generated day/period numbers).
  teacherAvailability?: Record<string, string[]>;
}

interface TimetableAssignment {
  classId: string;
  className: string;
  subjectName: string;
  teacherUid: string;
  day: number;
  period: number;
  // Stage 7 (added 2026-09-14) — "lockable editing with minimum
  // disruption." A locked assignment is one a human placed by hand (via
  // `moveTimetableAssignment`, which locks automatically — see its own
  // comment) or explicitly pinned (`setTimetableAssignmentLocked`). A
  // regenerate NEVER moves a locked assignment: see how `lockedAssignments`
  // is used below.
  locked?: boolean;
}

interface TimetableConflict {
  description: string;
  classId?: string;
  subjectName?: string;
  teacherUid?: string;
}

// Exported (not just an internal helper) specifically so this pure,
// deterministic function can be verified directly against synthetic data
// — see the real ad-hoc test run before this shipped. Firebase's deploy
// step only picks up actual onCall/onRequest exports, so exporting a
// plain function here changes nothing about what gets deployed.
export function generateTimetableSchedule(
  classes: TimetableClassInput[],
  config: TimetableConfigInput,
  lockedAssignments: TimetableAssignment[] = []
): { assignments: TimetableAssignment[]; conflicts: TimetableConflict[] } {
  // Locked assignments are carried over EXACTLY as they are — never
  // re-derived, never re-placed — and everything else is generated around
  // them. See the TimetableAssignment.locked doc comment for why.
  const assignments: TimetableAssignment[] = [...lockedAssignments];
  const conflicts: TimetableConflict[] = [];

  const slotKey = (day: number, period: number) => `${day}_${period}`;
  const classOccupancy = new Map<string, Set<string>>(); // "day_period" -> classIds occupied then
  const teacherOccupancy = new Map<string, Set<string>>(); // "day_period" -> teacherUids occupied then
  const teacherDailyLoad = new Map<string, number>(); // "teacherUid_day" -> periods already assigned that day

  const isClassFree = (classId: string, day: number, period: number) => !(classOccupancy.get(slotKey(day, period))?.has(classId) ?? false);
  const isTeacherFree = (teacherUid: string, day: number, period: number) => !(teacherOccupancy.get(slotKey(day, period))?.has(teacherUid) ?? false);
  const teacherDailyLoadFor = (teacherUid: string, day: number) => teacherDailyLoad.get(`${teacherUid}_${day}`) ?? 0;
  // Stage 3 — a teacher with no entry in `teacherAvailability` is available
  // every period, so this never changes behaviour for a school that hasn't
  // set any constraints.
  const isTeacherAvailable = (teacherUid: string, day: number, period: number) =>
    !(config.teacherAvailability?.[teacherUid]?.includes(slotKey(day, period)) ?? false);

  function occupy(classId: string, teacherUid: string, day: number, period: number) {
    const key = slotKey(day, period);
    if (!classOccupancy.has(key)) classOccupancy.set(key, new Set());
    classOccupancy.get(key)!.add(classId);
    if (!teacherOccupancy.has(key)) teacherOccupancy.set(key, new Set());
    teacherOccupancy.get(key)!.add(teacherUid);
    const loadKey = `${teacherUid}_${day}`;
    teacherDailyLoad.set(loadKey, (teacherDailyLoad.get(loadKey) ?? 0) + 1);
  }

  // Pre-occupy every locked slot FIRST, before anything else is placed —
  // this is what makes a regenerate never displace a locked assignment:
  // every other placement below can only land in slots these haven't
  // already claimed.
  for (const locked of lockedAssignments) {
    occupy(locked.classId, locked.teacherUid, locked.day, locked.period);
  }

  // Deterministic order — same input always produces the same schedule.
  const sortedClasses = [...classes].sort((a, b) => a.id.localeCompare(b.id));

  for (const cls of sortedClasses) {
    const sortedSubjects = [...cls.subjectNames].sort();
    for (const subject of sortedSubjects) {
      const teacherUid = cls.subjectTeacherUids[subject];
      if (!teacherUid) {
        conflicts.push({
          description: `${subject} for ${cls.classGrade} has no assigned teacher yet — connect this class's School Network screen and assign one before it can be scheduled.`,
          classId: cls.id,
          subjectName: subject,
        });
        continue;
      }

      const periodsPerWeek = config.subjectDefaults[subject] ?? 5;
      const isPractical = config.practicalSubjectsExceptionList.includes(subject);
      // Stage 7 — however many periods of this class+subject are already
      // locked in place count toward periodsPerWeek; only the remainder
      // needs placing. A teacher/subject pairing check isn't done here —
      // a locked assignment is trusted as-is, exactly like the brief's
      // "minimum disruption" intent.
      const alreadyLocked = lockedAssignments.filter((a) => a.classId === cls.id && a.subjectName === subject).length;
      const remaining = Math.max(0, periodsPerWeek - alreadyLocked);

      // Double-period rule (Stage 1): every non-practical subject is
      // scheduled ONLY as continuous 2-period blocks, never a lone single
      // period — an odd periods/week count genuinely can't fully satisfy
      // that, so it's flagged rather than silently rounded either way.
      const blocks: number[] = [];
      if (isPractical) {
        for (let i = 0; i < remaining; i++) blocks.push(1);
      } else {
        const doubleBlocks = Math.floor(remaining / 2);
        for (let i = 0; i < doubleBlocks; i++) blocks.push(2);
        if (remaining % 2 === 1) {
          conflicts.push({
            description:
              alreadyLocked > 0
                ? `${subject} for ${cls.classGrade} has ${remaining} period(s)/week still to place after ${alreadyLocked} locked period(s), which is odd and can't be fully scheduled as continuous double periods. Try locking an even number of periods, or changing this subject's periods/week.`
                : `${subject} for ${cls.classGrade} has an odd periods-per-week count (${periodsPerWeek}), which can't be fully scheduled as continuous double periods. Scheduling ${doubleBlocks * 2} of ${periodsPerWeek} periods — add ${subject} to the Practical Subjects Exception List, or change its periods/week to an even number, to resolve this.`,
            classId: cls.id,
            subjectName: subject,
          });
        }
      }

      for (const blockLength of blocks) {
        let placed = false;
        for (let day = 0; day < config.teachingDaysPerWeek && !placed; day++) {
          if (teacherDailyLoadFor(teacherUid, day) + blockLength > config.maxDailyPeriodsPerTeacher) continue;
          for (let period = 0; period + blockLength <= config.periodsPerDay; period++) {
            let free = true;
            for (let offset = 0; offset < blockLength; offset++) {
              const p = period + offset;
              if (!isClassFree(cls.id, day, p) || !isTeacherFree(teacherUid, day, p) || !isTeacherAvailable(teacherUid, day, p)) {
                free = false;
                break;
              }
            }
            if (!free) continue;
            for (let offset = 0; offset < blockLength; offset++) {
              const p = period + offset;
              occupy(cls.id, teacherUid, day, p);
              assignments.push({ classId: cls.id, className: cls.classGrade, subjectName: subject, teacherUid, day, period: p });
            }
            placed = true;
            break;
          }
        }
        if (!placed) {
          conflicts.push({
            description: `Could not find a free ${blockLength === 2 ? "double-period" : "single-period"} slot for ${subject} — ${cls.classGrade} without conflicting with this teacher's other classes, their daily load limit, or their stated availability. Try increasing periods/day, reducing this subject's periods/week, raising the max daily load, loosening this teacher's availability constraints, or reassigning the teacher.`,
            classId: cls.id,
            subjectName: subject,
            teacherUid,
          });
        }
      }
    }
  }

  return { assignments, conflicts };
}

interface GenerateTimetableRequest {
  schoolId: string;
}

export const generateTimetable = onCall<GenerateTimetableRequest>(
  { region: "us-central1", timeoutSeconds: 60, maxInstances: 5 },
  async (request): Promise<{ assignmentCount: number; conflictCount: number }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId } = request.data ?? {};
    if (!nonEmptyString(schoolId)) {
      throw new HttpsError("invalid-argument", "A school is required.");
    }

    const db = admin.firestore();
    const memberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    if (!callerCanManageTimetable(memberSnap.data())) {
      throw new HttpsError("permission-denied", "Only school leadership or an appointed Timetable Operator can run the timetable generator.");
    }
    const schoolSnap = await db.collection("schools").doc(schoolId).get();
    if (!schoolMeetsTimetableTier(schoolSnap.data())) {
      throw new HttpsError("failed-precondition", "Timetable Generation requires a Gold subscription or higher.");
    }

    const configSnap = await db.collection("schools").doc(schoolId).collection("timetable").doc("config").get();
    if (!configSnap.exists) {
      throw new HttpsError("failed-precondition", "Set up the timetable (periods/day, subjects, etc.) before generating one.");
    }
    const configData = configSnap.data()!;
    const config: TimetableConfigInput = {
      periodsPerDay: configData.periodsPerDay,
      teachingDaysPerWeek: configData.teachingDaysPerWeek,
      subjectDefaults: configData.subjectDefaults ?? {},
      practicalSubjectsExceptionList: configData.practicalSubjectsExceptionList ?? [],
      maxDailyPeriodsPerTeacher: configData.maxDailyPeriodsPerTeacher ?? configData.periodsPerDay,
      teacherAvailability: configData.teacherAvailability ?? undefined,
    };

    const classesSnap = await db.collection("schools").doc(schoolId).collection("classes").get();
    const classes: TimetableClassInput[] = classesSnap.docs.map((d) => ({
      id: d.id,
      classGrade: (d.data().classGrade as string) ?? d.id,
      subjectNames: (d.data().subjectNames as string[]) ?? [],
      subjectTeacherUids: (d.data().subjectTeacherUids as Record<string, string>) ?? {},
    }));
    if (classes.length === 0) {
      throw new HttpsError("failed-precondition", "No classes are connected to School Network yet — nothing to generate a timetable for.");
    }

    // Stage 7 — a regenerate must never move an assignment a human locked
    // by hand. Whatever's already locked on the CURRENT generated doc
    // (if any) is carried into the new run untouched.
    const existingGeneratedSnap = await db.collection("schools").doc(schoolId).collection("timetable").doc("generated").get();
    const lockedAssignments: TimetableAssignment[] = existingGeneratedSnap.exists
      ? ((existingGeneratedSnap.data()?.assignments as TimetableAssignment[]) ?? []).filter((a) => a.locked === true)
      : [];

    const { assignments, conflicts } = generateTimetableSchedule(classes, config, lockedAssignments);

    await db.collection("schools").doc(schoolId).collection("timetable").doc("generated").set({
      assignments,
      conflicts,
      generatedAt: admin.firestore.FieldValue.serverTimestamp(),
      generatedByUid: request.auth.uid,
    });

    return { assignmentCount: assignments.length, conflictCount: conflicts.length };
  }
);

// ---------------------------------------------------------------------
// Timetable Generation, Stage 6 (added 2026-09-14) — "When the
// deterministic engine cannot fully resolve all constraints, use AI to
// translate the raw conflict data into a plain-language explanation and
// suggested fix... The AI only explains and suggests here; actual
// conflict detection and validity checking stays with the deterministic
// engine." This function does exactly that and nothing more: it reads
// the conflicts `generateTimetable` already computed (never re-derives
// or re-validates them) and asks Gemini only to phrase each one more
// helpfully — the conflict LIST itself, and whether something is a
// conflict at all, is never something this function decides.
// ---------------------------------------------------------------------

const timetableConflictExplanationSchema = {
  type: "object",
  properties: {
    explanations: {
      type: "array",
      items: {
        type: "object",
        properties: {
          conflictIndex: { type: "integer", description: "Which conflict in the input list this explains (0-based)." },
          explanation: {
            type: "string",
            description:
              "One or two plain-language sentences explaining WHY this conflict happened, in terms a school " +
              "timetable operator (not a programmer) would understand. Never invent details not present in the " +
              "raw conflict description or the supplied context.",
          },
          suggestedFix: {
            type: "string",
            description:
              "One concrete, actionable suggestion for resolving it (e.g. naming a specific day/period to try, " +
              "or a specific setting to adjust) — grounded only in the real data supplied, never a fabricated " +
              "day/period/teacher name that wasn't in the context.",
          },
        },
        required: ["conflictIndex", "explanation", "suggestedFix"],
        additionalProperties: false,
      },
    },
  },
  required: ["explanations"],
  additionalProperties: false,
};

function buildTimetableConflictPrompt(
  conflicts: TimetableConflict[],
  config: TimetableConfigInput,
  teacherNames: Record<string, string>
): string {
  const conflictLines = conflicts
    .map((c, i) => `${i}. ${c.description}${c.teacherUid ? ` (teacher: ${teacherNames[c.teacherUid] ?? c.teacherUid})` : ""}`)
    .join("\n");
  return [
    "A deterministic (non-AI) school timetable scheduling engine already ran and could not resolve the " +
      "conflicts listed below. Your ONLY job is to explain each one in plain language for a school " +
      "timetable operator, and suggest ONE concrete fix — you are not re-checking or re-deciding whether " +
      "these are real conflicts; treat every one as already-confirmed real.",
    "",
    `School day structure: ${config.periodsPerDay} periods/day, ${config.teachingDaysPerWeek} teaching days/week, ` +
      `max ${config.maxDailyPeriodsPerTeacher} periods/day per teacher.`,
    "",
    "Conflicts (0-indexed):",
    conflictLines,
    "",
    "For each conflict, write a short explanation and one concrete suggested fix, grounded only in the real " +
      "data given above — never invent a day, period, teacher name, or subject that wasn't mentioned.",
  ].join("\n");
}

interface ExplainTimetableConflictsRequest {
  schoolId: string;
}

export const explainTimetableConflicts = onCall<ExplainTimetableConflictsRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 60, maxInstances: 5 },
  async (request): Promise<{ explanations: { conflictIndex: number; explanation: string; suggestedFix: string }[] }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId } = request.data ?? {};
    if (!nonEmptyString(schoolId)) {
      throw new HttpsError("invalid-argument", "A school is required.");
    }

    const db = admin.firestore();
    const memberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }

    const [generatedSnap, configSnap, membersSnap, schoolSnap] = await Promise.all([
      db.collection("schools").doc(schoolId).collection("timetable").doc("generated").get(),
      db.collection("schools").doc(schoolId).collection("timetable").doc("config").get(),
      db.collection("schools").doc(schoolId).collection("members").get(),
      db.collection("schools").doc(schoolId).get(),
    ]);
    if (!schoolMeetsTimetableTier(schoolSnap.data())) {
      throw new HttpsError("failed-precondition", "Timetable Generation requires a Gold subscription or higher.");
    }
    if (!generatedSnap.exists) {
      throw new HttpsError("failed-precondition", "No timetable has been generated yet.");
    }
    const conflicts = ((generatedSnap.data()?.conflicts as TimetableConflict[]) ?? []).slice(0, 30); // a real, sane cap — not an arbitrary AI-cost dodge
    if (conflicts.length === 0) {
      return { explanations: [] };
    }
    const configData = configSnap.data() ?? {};
    const config: TimetableConfigInput = {
      periodsPerDay: configData.periodsPerDay ?? 8,
      teachingDaysPerWeek: configData.teachingDaysPerWeek ?? 5,
      subjectDefaults: configData.subjectDefaults ?? {},
      practicalSubjectsExceptionList: configData.practicalSubjectsExceptionList ?? [],
      maxDailyPeriodsPerTeacher: configData.maxDailyPeriodsPerTeacher ?? 6,
    };
    const teacherNames: Record<string, string> = {};
    for (const doc of membersSnap.docs) {
      teacherNames[doc.id] = (doc.data().name as string) ?? doc.id;
    }

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: buildTimetableConflictPrompt(conflicts, config, teacherNames),
        config: { responseMimeType: "application/json", responseJsonSchema: timetableConflictExplanationSchema },
      });
      text = response.text;
    } catch (err) {
      console.error("explainTimetableConflicts: Gemini call failed", err);
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Could not generate explanations right now. The raw conflict list is still accurate.");
    }
    if (!text) {
      throw new HttpsError("internal", "The AI did not return a result.");
    }
    let parsed: { explanations: { conflictIndex: number; explanation: string; suggestedFix: string }[] };
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("explainTimetableConflicts: response was not valid JSON", text);
      throw new HttpsError("internal", "The explanation response could not be parsed.");
    }

    await db.collection("schools").doc(schoolId).collection("timetable").doc("generated").update({
      conflictExplanations: parsed.explanations,
      conflictExplanationsGeneratedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return parsed;
  }
);

// ---------------------------------------------------------------------
// Timetable Generation, Stage 3 (added 2026-09-14) — natural-language
// constraint entry. Per explicit requirement: "showing the operator the
// parsed result for confirmation before it's applied — never applying an
// AI interpretation silently." `parseTimetableConstraint` therefore only
// READS and interprets — it never writes anything. The actual day/period
// slot numbers a teacher becomes unavailable for are never generated by
// the AI at all: Gemini only extracts which WEEKDAYS and which
// time-of-day (morning/afternoon/all day) the text describes, and
// `computeUnavailableSlots` below turns that into concrete "day_period"
// keys with plain deterministic arithmetic against the school's real
// config — the same kind of AI/deterministic split as
// `explainTimetableConflicts` above, just drawn one step earlier. Once a
// human confirms the parsed result in the UI, the client calls
// `setTeacherAvailability` (for an availability constraint) or the
// existing `assignSubjectTeacher` (for an assignment constraint)
// separately — this function is never the one that applies anything.
// ---------------------------------------------------------------------

const TIMETABLE_WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

function timetableDayIndex(label: string): number {
  const key = label.trim().slice(0, 3).toLowerCase();
  if (!key) return -1;
  return TIMETABLE_WEEKDAYS.findIndex((d) => d.toLowerCase().startsWith(key));
}

// Deterministic — see the module comment above for why this, and not
// Gemini, computes the actual slot keys.
function computeUnavailableSlots(
  config: TimetableConfigInput,
  daysOfWeek: string[],
  timeOfDay: "morning" | "afternoon" | "all_day",
  constraintType: "unavailable" | "available_only"
): string[] {
  const matchedDays = daysOfWeek.map(timetableDayIndex).filter((i) => i >= 0 && i < config.teachingDaysPerWeek);
  const dayIndices = matchedDays.length > 0 ? matchedDays : Array.from({ length: config.teachingDaysPerWeek }, (_, i) => i);

  const half = Math.ceil(config.periodsPerDay / 2);
  const periodRange =
    timeOfDay === "morning"
      ? Array.from({ length: half }, (_, i) => i)
      : timeOfDay === "afternoon"
      ? Array.from({ length: Math.max(0, config.periodsPerDay - half) }, (_, i) => i + half)
      : Array.from({ length: config.periodsPerDay }, (_, i) => i);

  if (constraintType === "unavailable") {
    const slots: string[] = [];
    for (const day of dayIndices) for (const period of periodRange) slots.push(`${day}_${period}`);
    return slots;
  }

  // "available_only" — unavailable is everything OUTSIDE the described
  // days/time-of-day, not the described window itself.
  const availableSet = new Set<string>();
  for (const day of dayIndices) for (const period of periodRange) availableSet.add(`${day}_${period}`);
  const slots: string[] = [];
  for (let day = 0; day < config.teachingDaysPerWeek; day++) {
    for (let period = 0; period < config.periodsPerDay; period++) {
      const key = `${day}_${period}`;
      if (!availableSet.has(key)) slots.push(key);
    }
  }
  return slots;
}

const timetableConstraintSchema = {
  type: "object",
  properties: {
    kind: {
      type: "string",
      enum: ["availability", "assignment", "unrecognized"],
      description:
        "'availability' — the text describes when a teacher can or can't teach. 'assignment' — the text asks to " +
        "assign a teacher to teach a subject for a class. 'unrecognized' — neither, or too ambiguous to act on.",
    },
    teacherName: { type: "string", description: "The teacher's name exactly as it appears in the real names list below, or empty string if none is mentioned or no real name matches." },
    subjectName: { type: "string", description: "The subject mentioned, or empty string." },
    className: { type: "string", description: "The class/grade mentioned, or empty string." },
    constraintType: {
      type: "string",
      enum: ["unavailable", "available_only", ""],
      description:
        "For 'availability' kind only: 'unavailable' if the text states when the teacher CANNOT teach, " +
        "'available_only' if it states the ONLY time they CAN teach. Empty string for other kinds.",
    },
    daysOfWeek: {
      type: "array",
      items: { type: "string" },
      description: "Full weekday names mentioned (e.g. 'Monday', 'Wednesday'), or an empty array if no specific day is named (meaning every teaching day).",
    },
    timeOfDay: {
      type: "string",
      enum: ["morning", "afternoon", "all_day"],
      description: "For 'availability' kind: which part of the day. Use 'all_day' if the text doesn't distinguish morning/afternoon.",
    },
    summary: {
      type: "string",
      description: "One plain-language sentence restating exactly what was understood, for a human operator to confirm before anything is applied.",
    },
  },
  required: ["kind", "teacherName", "subjectName", "className", "constraintType", "daysOfWeek", "timeOfDay", "summary"],
  additionalProperties: false,
};

function buildTimetableConstraintPrompt(text: string, teacherNames: string[], classNames: string[], subjectNames: string[]): string {
  return [
    "A school timetable operator typed the instruction below into a free-text box. Extract its structured meaning " +
      "ONLY — you are not applying anything, just interpreting.",
    "",
    `Real teacher names at this school: ${teacherNames.length > 0 ? teacherNames.join(", ") : "(none on record)"}`,
    `Real class names at this school: ${classNames.length > 0 ? classNames.join(", ") : "(none on record)"}`,
    `Subjects already in this school's timetable setup: ${subjectNames.length > 0 ? subjectNames.join(", ") : "(none on record)"}`,
    "",
    `Operator's instruction: "${text}"`,
    "",
    "Only use a teacherName, className, or subjectName from the real lists above — if the instruction names someone " +
      "or something not on those lists, or is too vague to match confidently, leave that field as an empty string " +
      "rather than guessing. Never invent a name that isn't in the lists.",
  ].join("\n");
}

interface ParseTimetableConstraintRequest {
  schoolId: string;
  text: string;
}

export const parseTimetableConstraint = onCall<ParseTimetableConstraintRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (
    request
  ): Promise<{
    kind: "availability" | "assignment" | "unrecognized";
    teacherName: string;
    teacherUid: string | null;
    subjectName: string;
    className: string;
    classId: string | null;
    constraintType: "unavailable" | "available_only" | "";
    daysOfWeek: string[];
    timeOfDay: "morning" | "afternoon" | "all_day";
    summary: string;
    unavailableSlots: string[];
  }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, text } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !nonEmptyString(text)) {
      throw new HttpsError("invalid-argument", "A school and some instruction text are required.");
    }

    const db = admin.firestore();
    const memberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    if (!callerCanManageTimetable(memberSnap.data())) {
      throw new HttpsError("permission-denied", "Only school leadership or an appointed Timetable Operator can set up the timetable.");
    }
    const schoolSnap = await db.collection("schools").doc(schoolId).get();
    if (!schoolMeetsTimetableTier(schoolSnap.data())) {
      throw new HttpsError("failed-precondition", "Timetable Generation requires a Gold subscription or higher.");
    }

    const [membersSnap, classesSnap, configSnap] = await Promise.all([
      db.collection("schools").doc(schoolId).collection("members").get(),
      db.collection("schools").doc(schoolId).collection("classes").get(),
      db.collection("schools").doc(schoolId).collection("timetable").doc("config").get(),
    ]);
    const members = membersSnap.docs.map((d) => ({ uid: d.id, name: (d.data().name as string) ?? d.id }));
    const classes = classesSnap.docs.map((d) => ({ id: d.id, classGrade: (d.data().classGrade as string) ?? d.id }));
    const subjectNames = Object.keys((configSnap.data()?.subjectDefaults as Record<string, number>) ?? {});

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    let text_: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL_LITE,
        contents: buildTimetableConstraintPrompt(
          text,
          members.map((m) => m.name),
          classes.map((c) => c.classGrade),
          subjectNames
        ),
        config: { responseMimeType: "application/json", responseJsonSchema: timetableConstraintSchema },
      });
      text_ = response.text;
    } catch (err) {
      console.error("parseTimetableConstraint: Gemini call failed", err);
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Could not interpret that instruction right now.");
    }
    if (!text_) {
      throw new HttpsError("internal", "The AI did not return a result.");
    }
    let parsed: {
      kind: "availability" | "assignment" | "unrecognized";
      teacherName: string;
      subjectName: string;
      className: string;
      constraintType: "unavailable" | "available_only" | "";
      daysOfWeek: string[];
      timeOfDay: "morning" | "afternoon" | "all_day";
      summary: string;
    };
    try {
      parsed = JSON.parse(text_);
    } catch (err) {
      console.error("parseTimetableConstraint: response was not valid JSON", text_);
      throw new HttpsError("internal", "The response could not be parsed.");
    }

    const matchedTeacher = members.find((m) => m.name.trim().toLowerCase() === parsed.teacherName.trim().toLowerCase());
    const matchedClass = classes.find((c) => c.classGrade.trim().toLowerCase() === parsed.className.trim().toLowerCase());

    let unavailableSlots: string[] = [];
    if (parsed.kind === "availability" && matchedTeacher && parsed.constraintType) {
      if (!configSnap.exists) {
        throw new HttpsError("failed-precondition", "Set up the timetable (periods/day, teaching days, etc.) before setting teacher availability.");
      }
      const configData = configSnap.data()!;
      const config: TimetableConfigInput = {
        periodsPerDay: configData.periodsPerDay,
        teachingDaysPerWeek: configData.teachingDaysPerWeek,
        subjectDefaults: configData.subjectDefaults ?? {},
        practicalSubjectsExceptionList: configData.practicalSubjectsExceptionList ?? [],
        maxDailyPeriodsPerTeacher: configData.maxDailyPeriodsPerTeacher ?? configData.periodsPerDay,
      };
      unavailableSlots = computeUnavailableSlots(config, parsed.daysOfWeek, parsed.timeOfDay, parsed.constraintType);
    }

    return {
      kind: parsed.kind,
      teacherName: parsed.teacherName,
      teacherUid: matchedTeacher?.uid ?? null,
      subjectName: parsed.subjectName,
      className: parsed.className,
      classId: matchedClass?.id ?? null,
      constraintType: parsed.constraintType,
      daysOfWeek: parsed.daysOfWeek,
      timeOfDay: parsed.timeOfDay,
      summary: parsed.summary,
      unavailableSlots,
    };
  }
);

interface SetTeacherAvailabilityRequest {
  schoolId: string;
  teacherUid: string;
  unavailableSlots: string[];
}

export const setTeacherAvailability = onCall<SetTeacherAvailabilityRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, teacherUid, unavailableSlots } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !nonEmptyString(teacherUid) || !Array.isArray(unavailableSlots)) {
      throw new HttpsError("invalid-argument", "A school, a teacher, and a list of slots are required.");
    }
    const cleanSlots = unavailableSlots.filter((s): s is string => typeof s === "string" && /^\d+_\d+$/.test(s));

    const db = admin.firestore();
    const [callerSnap, teacherSnap] = await Promise.all([
      db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get(),
      db.collection("schools").doc(schoolId).collection("members").doc(teacherUid).get(),
    ]);
    if (!callerSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    if (!callerCanManageTimetable(callerSnap.data())) {
      throw new HttpsError("permission-denied", "Only school leadership or an appointed Timetable Operator can set up the timetable.");
    }
    const schoolSnap = await db.collection("schools").doc(schoolId).get();
    if (!schoolMeetsTimetableTier(schoolSnap.data())) {
      throw new HttpsError("failed-precondition", "Timetable Generation requires a Gold subscription or higher.");
    }
    if (!teacherSnap.exists) {
      throw new HttpsError("not-found", "That teacher is not a member of this school.");
    }

    await db
      .collection("schools")
      .doc(schoolId)
      .collection("timetable")
      .doc("config")
      .set(
        {
          teacherAvailability: { [teacherUid]: cleanSlots },
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedByUid: request.auth.uid,
        },
        { merge: true }
      );

    return { success: true };
  }
);

// ---------------------------------------------------------------------
// Timetable Generation, Stage 2 (added 2026-09-14) — "AI-assisted setup
// from photographed paper timetable." Mirrors the base64-image pattern
// `transcribeHandwrittenDocument` and `extractCoverPageFields` already
// use. This function ONLY reads and interprets a photographed paper
// timetable for one class — it never writes anything. The client shows
// every extracted value (day structure, subject/teacher rows) for
// review, matches teacher names against this school's REAL members
// itself, and only once a human confirms does it call the already-
// existing `saveTimetableConfig` and `assignSubjectTeacher` to actually
// apply anything — never a silent AI write, same discipline as Stage 3.
// ---------------------------------------------------------------------

interface ExtractTimetableFromPhotoRequest {
  schoolId: string;
  pageImagesBase64: string[];
}

interface ExtractedTimetableSubjectRow {
  name: string;
  periodsPerWeek: number;
  teacherName: string;
}

const extractTimetableFromPhotoSchema = {
  type: "object",
  properties: {
    periodsPerDay: { type: "integer", description: "The highest period number visible in the grid (how many teaching periods fit in one day). 0 if not determinable." },
    periodLengthMinutes: { type: "integer", description: "Each period's length in minutes, if written anywhere on the page (e.g. a time column like '08:00-08:40'). 0 if not written or not determinable." },
    teachingDaysPerWeek: { type: "integer", description: "How many distinct weekdays appear as columns/rows in the grid. 0 if not determinable." },
    subjects: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string", description: "The subject name exactly as written." },
          periodsPerWeek: { type: "integer", description: "How many times this subject appears across the whole week's grid for this class." },
          teacherName: { type: "string", description: "The teacher's name as written next to/under this subject in the grid, or empty string if no name is shown." },
        },
        required: ["name", "periodsPerWeek", "teacherName"],
        additionalProperties: false,
      },
      description: "One entry per distinct subject appearing anywhere in the grid — do not list the same subject twice.",
    },
    notes: {
      type: "string",
      description: "Anything a reader should double check — a smudged cell, an ambiguous abbreviation, a day/period that couldn't be read. Empty string if nothing stood out.",
    },
  },
  required: ["periodsPerDay", "periodLengthMinutes", "teachingDaysPerWeek", "subjects", "notes"],
  additionalProperties: false,
};

function buildExtractTimetablePrompt(teacherNames: string[]): string {
  return [
    "The attached image(s) are photo(s) of a paper timetable grid for ONE school class (days across the top or " +
      "side, periods down the other axis, each cell naming a subject and often a teacher). Read only what is " +
      "genuinely written — never invent a subject, teacher, or count that isn't actually shown.",
    "1. periodsPerDay — the highest period number that appears (how many periods make up one teaching day).",
    "2. periodLengthMinutes — only if an actual time range is written somewhere (e.g. '08:00-08:40' = 40); " +
      "otherwise 0.",
    "3. teachingDaysPerWeek — how many distinct weekdays appear in the grid.",
    "4. subjects — one entry per DISTINCT subject name that appears anywhere in the grid, with periodsPerWeek " +
      "counting every cell across the whole week that names it, and teacherName read from whatever is written " +
      "in or near those cells (leave empty if no name is shown for that subject).",
    `Real teacher names already on record at this school, for reference only (a name in the photo might match one ` +
      `of these, or might be someone not yet on record — write exactly what's on the page either way): ` +
      `${teacherNames.length > 0 ? teacherNames.join(", ") : "(none on record)"}`,
    "5. If any cell is smudged, cut off, or ambiguous, still give your best reading but say so in notes rather " +
      "than silently guessing without flagging it.",
  ].join("\n");
}

export const extractTimetableFromPhoto = onCall<ExtractTimetableFromPhotoRequest>(
  { secrets: [geminiApiKey], region: "us-central1", timeoutSeconds: 120, memory: "512MiB", maxInstances: 5 },
  async (
    request
  ): Promise<{
    periodsPerDay: number;
    periodLengthMinutes: number;
    teachingDaysPerWeek: number;
    subjects: (ExtractedTimetableSubjectRow & { teacherUid: string | null })[];
    notes: string;
  }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, pageImagesBase64 } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !Array.isArray(pageImagesBase64) || pageImagesBase64.length === 0) {
      throw new HttpsError("invalid-argument", "A school and at least one photo are required.");
    }

    const db = admin.firestore();
    const memberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    if (!callerCanManageTimetable(memberSnap.data())) {
      throw new HttpsError("permission-denied", "Only school leadership or an appointed Timetable Operator can set up the timetable.");
    }
    const schoolSnap = await db.collection("schools").doc(schoolId).get();
    if (!schoolMeetsTimetableTier(schoolSnap.data())) {
      throw new HttpsError("failed-precondition", "Timetable Generation requires a Gold subscription or higher.");
    }

    const membersSnap = await db.collection("schools").doc(schoolId).collection("members").get();
    const members = membersSnap.docs.map((d) => ({ uid: d.id, name: (d.data().name as string) ?? d.id }));

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    const imageParts = pageImagesBase64.map((b64: string) => ({ inlineData: { mimeType: "image/jpeg", data: b64 } }));
    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: [{ role: "user", parts: [{ text: buildExtractTimetablePrompt(members.map((m) => m.name)) }, ...imageParts] }],
        config: { responseMimeType: "application/json", responseJsonSchema: extractTimetableFromPhotoSchema },
      });
      text = response.text;
    } catch (err) {
      console.error("extractTimetableFromPhoto: Gemini call failed", err);
      throw quotaExhaustedError(err) ?? new HttpsError("internal", "Could not read this timetable right now. Please try again.");
    }
    if (!text) {
      throw new HttpsError("internal", "The AI did not return a result.");
    }
    let parsed: {
      periodsPerDay: number;
      periodLengthMinutes: number;
      teachingDaysPerWeek: number;
      subjects: ExtractedTimetableSubjectRow[];
      notes: string;
    };
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      console.error("extractTimetableFromPhoto: response was not valid JSON", text);
      throw new HttpsError("internal", "The response could not be parsed.");
    }

    const subjectsWithMatches = parsed.subjects.map((s) => {
      const matched = members.find((m) => m.name.trim().toLowerCase() === s.teacherName.trim().toLowerCase());
      return { ...s, teacherUid: matched?.uid ?? null };
    });

    return { ...parsed, subjects: subjectsWithMatches };
  }
);

// ---------------------------------------------------------------------
// Timetable Generation, Stage 9 (added 2026-09-14) — "co-opted Timetable
// Operator" appointment. Grants/revokes the `timetableOperator` flag
// `callerCanManageTimetable` checks (see its own comment above). Kept
// leadership/administrator-only on purpose — an operator can manage the
// timetable but can't co-opt other operators, so this power doesn't
// self-propagate past whoever leadership actually chose.
// ---------------------------------------------------------------------

interface SetTimetableOperatorRequest {
  schoolId: string;
  targetUid: string;
  isOperator: boolean;
}

export const setTimetableOperator = onCall<SetTimetableOperatorRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, targetUid, isOperator } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !nonEmptyString(targetUid) || typeof isOperator !== "boolean") {
      throw new HttpsError("invalid-argument", "A school, a target teacher, and a true/false value are required.");
    }

    const db = admin.firestore();
    const membersRef = db.collection("schools").doc(schoolId).collection("members");
    const [callerSnap, targetSnap] = await Promise.all([membersRef.doc(request.auth.uid).get(), membersRef.doc(targetUid).get()]);
    if (!callerSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const callerRole = callerSnap.data()?.role as SchoolRole;
    if (!LEADERSHIP_ROLES.includes(callerRole) && callerRole !== "administrator") {
      throw new HttpsError("permission-denied", "Only school leadership can appoint a Timetable Operator.");
    }
    if (!targetSnap.exists) {
      throw new HttpsError("not-found", "That teacher is not a member of this school.");
    }

    await membersRef.doc(targetUid).update({ timetableOperator: isOperator });
    return { success: true };
  }
);

// ---------------------------------------------------------------------
// Timetable Generation, Stages 5 & 7 (added 2026-09-14) — manual editing
// with real-time conflict detection and "minimum disruption" locking.
// `moveTimetableAssignment` is the ONLY way a generated assignment's
// day/period ever changes by hand: it re-checks the exact same rules the
// deterministic engine enforces (no double-booking a class or teacher, no
// exceeding max daily load, respecting stated availability) against the
// CURRENT generated schedule before writing anything — a rejected move
// changes nothing, it just reports why. A successful move auto-locks the
// assignment (see TimetableAssignment.locked) so a later "Regenerate"
// never quietly undoes a human's manual fix.
// ---------------------------------------------------------------------

interface MoveTimetableAssignmentRequest {
  schoolId: string;
  classId: string;
  subjectName: string;
  teacherUid: string;
  day: number;
  period: number;
  newDay: number;
  newPeriod: number;
}

export const moveTimetableAssignment = onCall<MoveTimetableAssignmentRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, subjectName, teacherUid, day, period, newDay, newPeriod } = request.data ?? {};
    if (
      !nonEmptyString(schoolId) ||
      !nonEmptyString(classId) ||
      !nonEmptyString(subjectName) ||
      !nonEmptyString(teacherUid) ||
      typeof day !== "number" ||
      typeof period !== "number" ||
      typeof newDay !== "number" ||
      typeof newPeriod !== "number"
    ) {
      throw new HttpsError("invalid-argument", "A school, class, subject, teacher, current slot, and target slot are all required.");
    }

    const db = admin.firestore();
    const memberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    if (!callerCanManageTimetable(memberSnap.data())) {
      throw new HttpsError("permission-denied", "Only school leadership or an appointed Timetable Operator can edit the timetable.");
    }
    const schoolSnap = await db.collection("schools").doc(schoolId).get();
    if (!schoolMeetsTimetableTier(schoolSnap.data())) {
      throw new HttpsError("failed-precondition", "Timetable Generation requires a Gold subscription or higher.");
    }

    const [generatedSnap, configSnap] = await Promise.all([
      db.collection("schools").doc(schoolId).collection("timetable").doc("generated").get(),
      db.collection("schools").doc(schoolId).collection("timetable").doc("config").get(),
    ]);
    if (!generatedSnap.exists) {
      throw new HttpsError("failed-precondition", "No timetable has been generated yet.");
    }
    const configData = configSnap.data() ?? {};
    const periodsPerDay = (configData.periodsPerDay as number) ?? 8;
    const teachingDaysPerWeek = (configData.teachingDaysPerWeek as number) ?? 5;
    const maxDailyPeriodsPerTeacher = (configData.maxDailyPeriodsPerTeacher as number) ?? periodsPerDay;
    const teacherAvailability = (configData.teacherAvailability as Record<string, string[]>) ?? {};

    if (newDay < 0 || newDay >= teachingDaysPerWeek || newPeriod < 0 || newPeriod >= periodsPerDay) {
      throw new HttpsError("invalid-argument", "That slot is outside the school's current day structure.");
    }

    const assignments = ((generatedSnap.data()?.assignments as TimetableAssignment[]) ?? []).slice();
    const targetIndex = assignments.findIndex(
      (a) => a.classId === classId && a.subjectName === subjectName && a.teacherUid === teacherUid && a.day === day && a.period === period
    );
    if (targetIndex === -1) {
      throw new HttpsError("not-found", "That lesson could not be found — the timetable may have changed. Refresh and try again.");
    }
    if (day === newDay && period === newPeriod) {
      return { success: true }; // no-op — nothing to check or change
    }

    const others = assignments.filter((_, i) => i !== targetIndex);
    const conflictingClass = others.find((a) => a.classId === classId && a.day === newDay && a.period === newPeriod);
    if (conflictingClass) {
      throw new HttpsError("failed-precondition", `${conflictingClass.className} already has ${conflictingClass.subjectName} at that slot.`);
    }
    const conflictingTeacher = others.find((a) => a.teacherUid === teacherUid && a.day === newDay && a.period === newPeriod);
    if (conflictingTeacher) {
      throw new HttpsError("failed-precondition", `This teacher already has ${conflictingTeacher.subjectName} for ${conflictingTeacher.className} at that slot.`);
    }
    if (teacherAvailability[teacherUid]?.includes(`${newDay}_${newPeriod}`)) {
      throw new HttpsError("failed-precondition", "This teacher has marked themselves unavailable at that slot.");
    }
    const newDayLoad = others.filter((a) => a.teacherUid === teacherUid && a.day === newDay).length + 1;
    if (newDayLoad > maxDailyPeriodsPerTeacher) {
      throw new HttpsError("failed-precondition", `This teacher would exceed their max daily load (${maxDailyPeriodsPerTeacher}) on that day.`);
    }

    assignments[targetIndex] = { ...assignments[targetIndex], day: newDay, period: newPeriod, locked: true };
    await db.collection("schools").doc(schoolId).collection("timetable").doc("generated").update({
      assignments,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedByUid: request.auth.uid,
    });

    return { success: true };
  }
);

interface SetTimetableAssignmentLockedRequest {
  schoolId: string;
  classId: string;
  subjectName: string;
  teacherUid: string;
  day: number;
  period: number;
  locked: boolean;
}

export const setTimetableAssignmentLocked = onCall<SetTimetableAssignmentLockedRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, subjectName, teacherUid, day, period, locked } = request.data ?? {};
    if (
      !nonEmptyString(schoolId) ||
      !nonEmptyString(classId) ||
      !nonEmptyString(subjectName) ||
      !nonEmptyString(teacherUid) ||
      typeof day !== "number" ||
      typeof period !== "number" ||
      typeof locked !== "boolean"
    ) {
      throw new HttpsError("invalid-argument", "A school, class, subject, teacher, slot, and lock value are all required.");
    }

    const db = admin.firestore();
    const memberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    if (!callerCanManageTimetable(memberSnap.data())) {
      throw new HttpsError("permission-denied", "Only school leadership or an appointed Timetable Operator can edit the timetable.");
    }
    const schoolSnap = await db.collection("schools").doc(schoolId).get();
    if (!schoolMeetsTimetableTier(schoolSnap.data())) {
      throw new HttpsError("failed-precondition", "Timetable Generation requires a Gold subscription or higher.");
    }

    const generatedRef = db.collection("schools").doc(schoolId).collection("timetable").doc("generated");
    const generatedSnap = await generatedRef.get();
    if (!generatedSnap.exists) {
      throw new HttpsError("failed-precondition", "No timetable has been generated yet.");
    }
    const assignments = ((generatedSnap.data()?.assignments as TimetableAssignment[]) ?? []).slice();
    const targetIndex = assignments.findIndex(
      (a) => a.classId === classId && a.subjectName === subjectName && a.teacherUid === teacherUid && a.day === day && a.period === period
    );
    if (targetIndex === -1) {
      throw new HttpsError("not-found", "That lesson could not be found — the timetable may have changed. Refresh and try again.");
    }

    assignments[targetIndex] = { ...assignments[targetIndex], locked };
    await generatedRef.update({ assignments });

    return { success: true };
  }
);

// ---------------------------------------------------------------------
// Home Assignment epic, Stages 5 & 6 (added 2026-09-14) — "Home
// Assignment: topic & format selection" + "Marking key generation &
// labeling." One Gemini call produces BOTH the assignment questions and
// a matching marking-key entry per question (same number, in the same
// order) — generating them together, not as two separate calls, is what
// guarantees the key actually matches the assignment's own numbering
// with no separate reconciliation step. Same grounding discipline as
// `generateLessonPlan` above: only the syllabus competencies/objectives/
// references/subjectContentExcerpt the client supplies, nothing else —
// "no fabricated content" per the brief. Never auto-applied: this
// function only returns a draft: the client routes it through
// MarkingSchemeBuilderScreen for the teacher's own review before saving
// (see that screen's own doc comment on why there's exactly one save
// path for every marking scheme in this app).
// ---------------------------------------------------------------------

interface GenerateHomeAssignmentRequest {
  topic: string;
  subtopic?: string;
  subject: string;
  grade?: string;
  competencies: string[];
  objectives: string[];
  references?: string;
  subjectContentExcerpt?: string;
  pageLength: "one" | "two";
  questionType: "summative" | "formative";
}

interface GenerateHomeAssignmentQuestion {
  number: string;
  text: string;
  maxMarks: number;
}

interface GenerateHomeAssignmentKeyEntry {
  number: string;
  expectedAnswerOrKeywords: string;
}

interface GenerateHomeAssignmentResponse {
  title: string;
  instructions: string;
  questions: GenerateHomeAssignmentQuestion[];
  markingKey: GenerateHomeAssignmentKeyEntry[];
  notes: string;
}

const generateHomeAssignmentSchema = {
  type: "object",
  properties: {
    title: { type: "string", description: "A short, descriptive title for this home assignment — never generic like 'Assignment'." },
    instructions: {
      type: "string",
      description: "1-2 plain-language sentences telling the learner how to complete and record their answers (e.g. 'Answer all questions in your exercise book, showing your working.').",
    },
    questions: {
      type: "array",
      description: "The assignment questions, in order.",
      items: {
        type: "object",
        properties: {
          number: { type: "string", description: "Question number/label as a learner would see it, e.g. '1', '2', '2a'." },
          text: { type: "string", description: "The full question text, exactly as a learner would read it. No Markdown." },
          maxMarks: { type: "number", description: "Marks this question is worth." },
        },
        required: ["number", "text", "maxMarks"],
        additionalProperties: false,
      },
    },
    markingKey: {
      type: "array",
      description: "Exactly one entry per question above, same numbers, same order — never more, never fewer.",
      items: {
        type: "object",
        properties: {
          number: { type: "string", description: "Must exactly match one question's own number above." },
          expectedAnswerOrKeywords: {
            type: "string",
            description: "The model answer, or a comma/line-separated list of keywords a grader (human or AI) should look for.",
          },
        },
        required: ["number", "expectedAnswerOrKeywords"],
        additionalProperties: false,
      },
    },
    notes: {
      type: "string",
      description: "Anything a teacher should double-check before sending this out — e.g. if the syllabus context was too thin to fill the requested length responsibly. Empty string if nothing stood out.",
    },
  },
  required: ["title", "instructions", "questions", "markingKey", "notes"],
  additionalProperties: false,
};

function buildHomeAssignmentPrompt(req: GenerateHomeAssignmentRequest): string {
  const pageGuidance =
    req.pageLength === "two"
      ? "Fill roughly TWO A4 pages worth of questions for a learner to complete at home — a substantial set (typically 8-14 questions, depending on what the subject/topic genuinely supports). Do not pad with filler, but do produce enough real content to genuinely fill two pages."
      : "Fill roughly ONE A4 page worth of questions for a learner to complete at home — a focused, shorter set (typically 4-8 questions). Do not pad or under-fill.";
  const typeGuidance =
    req.questionType === "summative"
      ? "SUMMATIVE questions: test overall understanding/mastery of the topic once it's been taught — structured, gradeable questions (short-answer, structured/essay, or calculation, whichever fits the subject) suitable for recording a real mark."
      : "FORMATIVE questions: check understanding WHILE learning is still happening — can include lower-stakes checks (fill-in-the-blank, explain-in-your-own-words, quick application) pitched at practice/reinforcement rather than final assessment, but every question still carries real marks so the marking key stays consistent.";
  return [
    "Write a Home Assignment — a set of questions a Zambian secondary-school teacher gives learners to complete AT HOME — for exactly one topic, covering only the syllabus content below. Do not introduce content outside its scope.",
    "",
    `Subject: ${req.subject}`,
    req.grade ? `Grade/Form: ${req.grade}` : null,
    `Topic: ${req.topic}`,
    req.subtopic ? `Sub-topic: ${req.subtopic}` : null,
    "",
    "Syllabus context — every question must cover only this, nothing else:",
    ...req.competencies.map((c) => `- ${c}`),
    ...req.objectives.map((o) => `- ${o}`),
    "",
    pageGuidance,
    typeGuidance,
    "",
    req.references
      ? "References available for this assignment (cite naturally where relevant, never invent a citation not " +
        `listed here):\n${req.references}`
      : null,
    req.subjectContentExcerpt
      ? "Real material already saved on this teacher's own device for this exact topic — ground the questions in " +
        "this FIRST, before anything else. Only bring in your own general knowledge to fill gaps this material " +
        `doesn't cover, and never contradict what's given here:\n${req.subjectContentExcerpt}\n`
      : null,
    "For EVERY question, produce a matching marking-key entry with the SAME number and a real model answer or " +
      "grading keywords — never leave a question without a matching key entry, and never add a key entry with no " +
      "matching question.",
    "Write in plain text only — no Markdown formatting of any kind (no #, ##, **, *, __, ---, or backticks). This " +
      "is a document a teacher will print and hand to learners, not a chat reply.",
    "If the syllabus context above is too thin to responsibly write a full assignment at the requested length, " +
      "say so explicitly in notes rather than inventing or padding content to fill the gap.",
  ]
    .filter((line): line is string => line !== null)
    .join("\n");
}

export const generateHomeAssignment = onCall<GenerateHomeAssignmentRequest>(
  { secrets: [geminiApiKey], region: "us-central1", maxInstances: 5 },
  async (request): Promise<GenerateHomeAssignmentResponse> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to generate a home assignment.");
    }
    const { topic, subtopic, subject, grade, competencies, objectives, references, subjectContentExcerpt, pageLength, questionType } =
      request.data ?? {};

    if (typeof topic !== "string" || topic.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'topic' is required.");
    }
    if (typeof subject !== "string" || subject.trim().length === 0) {
      throw new HttpsError("invalid-argument", "'subject' is required.");
    }
    if (!Array.isArray(competencies) || !competencies.every((c) => typeof c === "string")) {
      throw new HttpsError("invalid-argument", "'competencies' must be a string array.");
    }
    if (!Array.isArray(objectives) || !objectives.every((o) => typeof o === "string")) {
      throw new HttpsError("invalid-argument", "'objectives' must be a string array.");
    }
    if (competencies.length === 0 && objectives.length === 0) {
      throw new HttpsError("invalid-argument", "At least one competency or objective is required — a home assignment cannot be grounded in nothing.");
    }
    if (pageLength !== "one" && pageLength !== "two") {
      throw new HttpsError("invalid-argument", "'pageLength' must be 'one' or 'two'.");
    }
    if (questionType !== "summative" && questionType !== "formative") {
      throw new HttpsError("invalid-argument", "'questionType' must be 'summative' or 'formative'.");
    }

    const req: GenerateHomeAssignmentRequest = {
      topic,
      subtopic: typeof subtopic === "string" ? subtopic : undefined,
      subject,
      grade: typeof grade === "string" ? grade : undefined,
      competencies,
      objectives,
      references: typeof references === "string" ? references : undefined,
      subjectContentExcerpt: typeof subjectContentExcerpt === "string" ? subjectContentExcerpt : undefined,
      pageLength,
      questionType,
    };

    const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });
    let text: string | undefined;
    try {
      const response = await ai.models.generateContent({
        model: GEMINI_MODEL,
        contents: buildHomeAssignmentPrompt(req),
        config: { responseMimeType: "application/json", responseJsonSchema: generateHomeAssignmentSchema },
      });
      text = response.text;
    } catch (err) {
      console.error("generateHomeAssignment: Gemini call failed", err);
      throw quotaExhaustedError(err) ??
        new HttpsError("internal", "Could not generate this home assignment right now. Please try again.");
    }
    if (!text) {
      throw new HttpsError("internal", "The AI did not return a result.");
    }
    try {
      return JSON.parse(text) as GenerateHomeAssignmentResponse;
    } catch (err) {
      console.error("generateHomeAssignment: response was not valid JSON", text);
      throw new HttpsError("internal", "The response could not be parsed.");
    }
  }
);

// ---------------------------------------------------------------------
// Home Assignment epic, Stage 1/7/8 (added 2026-09-14) — a Pupil-role
// account linking itself to a real class roster slot. Deliberately kept
// OUT of `schools/{id}/members` (that collection, and its `role` field,
// is School Network STAFF only — a pupil is a different kind of account
// with no SchoolRole at all): a pupil's access is gated by its own
// `pupilSchoolId`/`pupilClassId` custom claims instead, set only here,
// never touching `schoolId`/`schoolRole`. Two-step by design (request,
// then a real teacher confirms) per the explicit decision to keep a
// human in the loop against a pupil mistakenly (or deliberately) joining
// the wrong roster slot.
// ---------------------------------------------------------------------

interface ListSchoolClassesByCodeRequest {
  schoolCode: string;
}

// A pupil has no `schoolId`/`pupilSchoolId` claim yet at this point in the
// flow, so they can't read `schools/{id}/classes` directly under
// firestore.rules — this is the one, deliberately low-sensitivity lookup
// (class grade/term only, nothing a stranger couldn't already guess) that
// lets them see what to pick from before any claim exists. The school
// CODE itself is the real gate here, same trust model `joinSchoolByCode`
// already uses.
export const listSchoolClassesByCode = onCall<ListSchoolClassesByCodeRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ schoolId: string; schoolName: string; classes: { id: string; classGrade: string; term: string }[] }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolCode } = request.data ?? {};
    if (!nonEmptyString(schoolCode, 12)) {
      throw new HttpsError("invalid-argument", "A school code is required.");
    }
    const db = admin.firestore();
    const matches = await db.collection("schools").where("code", "==", schoolCode.trim().toUpperCase()).limit(1).get();
    if (matches.empty) {
      throw new HttpsError("not-found", "That school code doesn't match any registered school. Double-check it with your teacher.");
    }
    const schoolDoc = matches.docs[0];
    const classesSnap = await schoolDoc.ref.collection("classes").get();
    return {
      schoolId: schoolDoc.id,
      schoolName: (schoolDoc.data().name as string) ?? "",
      classes: classesSnap.docs.map((d) => ({
        id: d.id,
        classGrade: (d.data().classGrade as string) ?? "",
        term: (d.data().term as string) ?? "",
      })),
    };
  }
);

interface RequestPupilClassLinkRequest {
  schoolCode: string;
  classId: string;
  learnerName: string;
}

export const requestPupilClassLink = onCall<RequestPupilClassLinkRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ schoolId: string; schoolName: string; className: string }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolCode, classId, learnerName } = request.data ?? {};
    if (!nonEmptyString(schoolCode, 12) || !nonEmptyString(classId) || !nonEmptyString(learnerName)) {
      throw new HttpsError("invalid-argument", "A school code, class, and your name are required.");
    }

    const db = admin.firestore();
    const matches = await db.collection("schools").where("code", "==", schoolCode.trim().toUpperCase()).limit(1).get();
    if (matches.empty) {
      throw new HttpsError("not-found", "That school code doesn't match any registered school. Double-check it with your teacher.");
    }
    const schoolDoc = matches.docs[0];
    const classRef = schoolDoc.ref.collection("classes").doc(classId);
    const classSnap = await classRef.get();
    if (!classSnap.exists) {
      throw new HttpsError("not-found", "That class could not be found at this school.");
    }
    const learnerNames = (classSnap.data()?.learnerNames as string[] | undefined) ?? [];
    const trimmedName = learnerName.trim();
    if (!learnerNames.includes(trimmedName)) {
      throw new HttpsError("failed-precondition", "That name isn't on this class's roster yet — check the exact spelling with your teacher.");
    }

    await classRef.collection("pupilClassLinks").doc(request.auth.uid).set({
      learnerName: trimmedName,
      requestedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { schoolId: schoolDoc.id, schoolName: (schoolDoc.data().name as string) ?? "", className: (classSnap.data()?.classGrade as string) ?? "" };
  }
);

interface RespondToPupilClassLinkRequest {
  schoolId: string;
  classId: string;
  pupilUid: string;
  approve: boolean;
}

export const respondToPupilClassLink = onCall<RespondToPupilClassLinkRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, pupilUid, approve } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !nonEmptyString(classId) || !nonEmptyString(pupilUid) || typeof approve !== "boolean") {
      throw new HttpsError("invalid-argument", "A school, class, pupil, and true/false decision are required.");
    }

    const db = admin.firestore();
    const classRef = db.collection("schools").doc(schoolId).collection("classes").doc(classId);
    const linkRef = classRef.collection("pupilClassLinks").doc(pupilUid);
    const [classSnap, callerMemberSnap, linkSnap] = await Promise.all([
      classRef.get(),
      db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get(),
      linkRef.get(),
    ]);
    if (!classSnap.exists) {
      throw new HttpsError("not-found", "That class is not connected to this school.");
    }
    if (!callerMemberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    if (!linkSnap.exists) {
      throw new HttpsError("not-found", "That join request no longer exists — it may have already been handled.");
    }
    const classData = classSnap.data()!;
    const callerRole = callerMemberSnap.data()?.role as SchoolRole;
    const isLeadership = LEADERSHIP_ROLES.includes(callerRole) || callerRole === "administrator";
    const isThisClassGradeTeacher = classData.gradeTeacherUid === request.auth.uid;
    if (!isLeadership && !isThisClassGradeTeacher) {
      throw new HttpsError("permission-denied", "Only this class's Grade Teacher, or school leadership, can confirm a pupil's join request.");
    }

    if (approve) {
      const learnerName = linkSnap.data()?.learnerName as string;
      const learnerUids: Record<string, string> = { ...(classData.learnerUids ?? {}) };
      learnerUids[learnerName] = pupilUid;
      await classRef.update({ learnerUids });

      const pupilUser = await admin.auth().getUser(pupilUid);
      await admin.auth().setCustomUserClaims(pupilUid, {
        ...(pupilUser.customClaims ?? {}),
        pupilSchoolId: schoolId,
        pupilClassId: classId,
      });
    }
    await linkRef.delete();

    return { success: true };
  }
);

// ---------------------------------------------------------------------
// Home Assignment epic, Stage 7 (added 2026-09-14) — "Send to Class." A
// Home Assignment doc is only ever CREATED here, at send time (not at
// generation — Stage 5's review screen can be discarded/regenerated with
// nothing left behind). Distribution reuses `broadcastToGuardians`'
// exact loop-per-recipient email pattern and its "server can't open
// WhatsApp, return the recipient list to the client" approach for
// WhatsApp — the one real difference is this carries a real file
// attachment (the client-built assignment PDF), which broadcastToGuardians
// never needed. In-app delivery needs NO separate step at all: a linked
// pupil's app already reads this same `homeAssignments` collection (see
// firestore.rules), so the write below IS the in-app delivery.
// ---------------------------------------------------------------------

interface HomeAssignmentQuestionInput {
  number: string;
  text: string;
  maxMarks: number;
}

interface HomeAssignmentKeyEntryInput {
  number: string;
  expectedAnswerOrKeywords: string;
}

// Home Assignment reply-ingestion epic, Stage 1 (added 2026-09-16, per
// explicit request) — a short, human-typeable reference code embedded
// in every assignment's email subject and WhatsApp message, so a
// pupil/guardian's reply (however it eventually reaches the teacher —
// an inbound email webhook, or a manually-imported photo) can be tied
// back to the exact assignment/marking-key/roster it belongs to. Not a
// security token — collision risk across one school's own assignments
// is negligible for this "which assignment is this a reply to" purpose,
// not for anything access-control-relevant.
function generateHomeAssignmentReferenceCode(subjectName: string): string {
  const abbr = subjectName.replace(/[^A-Za-z]/g, "").toUpperCase().slice(0, 4) || "HMWK";
  const now = new Date();
  const yy = String(now.getFullYear() % 100).padStart(2, "0");
  const mm = String(now.getMonth() + 1).padStart(2, "0");
  const dd = String(now.getDate()).padStart(2, "0");
  const suffix = Math.random().toString(36).slice(2, 4).toUpperCase().padEnd(2, "0");
  return `HA-${abbr}-${yy}${mm}${dd}-${suffix}`;
}

interface SendHomeAssignmentToClassRequest {
  schoolId: string;
  classId: string;
  subjectName: string;
  title: string;
  instructions: string;
  questions: HomeAssignmentQuestionInput[];
  markingKeyTitle: string;
  markingKey: HomeAssignmentKeyEntryInput[];
  deadlineIso?: string;
  attachment?: { filename: string; base64: string };
}

export const sendHomeAssignmentToClass = onCall<SendHomeAssignmentToClassRequest>(
  { secrets: [brevoApiKey, brevoSenderEmail], region: "us-central1", timeoutSeconds: 180, memory: "256MiB", maxInstances: 5 },
  async (
    request
  ): Promise<{
    assignmentId: string;
    referenceCode: string;
    emailsSent: number;
    emailsFailed: number;
    whatsappRecipients: { name: string; phone: string }[];
  }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, subjectName, title, instructions, questions, markingKeyTitle, markingKey, deadlineIso, attachment } = request.data ?? {};
    if (
      !nonEmptyString(schoolId) ||
      !nonEmptyString(classId) ||
      !nonEmptyString(subjectName, 60) ||
      !nonEmptyString(title, 200) ||
      !Array.isArray(questions) ||
      questions.length === 0 ||
      !Array.isArray(markingKey)
    ) {
      throw new HttpsError("invalid-argument", "A school, class, subject, title, and at least one question are required.");
    }
    if (deadlineIso !== undefined && typeof deadlineIso !== "string") {
      throw new HttpsError("invalid-argument", "'deadlineIso' must be a string if provided.");
    }

    const db = admin.firestore();
    const classRef = db.collection("schools").doc(schoolId).collection("classes").doc(classId);
    const [classSnap, callerMemberSnap] = await Promise.all([
      classRef.get(),
      db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get(),
    ]);
    if (!classSnap.exists) {
      throw new HttpsError("not-found", "That class is not connected to this school.");
    }
    if (!callerMemberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const classData = classSnap.data()!;
    const callerRole = callerMemberSnap.data()?.role as SchoolRole;
    const isLeadership = LEADERSHIP_ROLES.includes(callerRole) || callerRole === "administrator";
    const isThisSubjectTeacher = (classData.subjectTeacherUids ?? {})[subjectName] === request.auth.uid;
    if (!isLeadership && !isThisSubjectTeacher) {
      throw new HttpsError("permission-denied", "Only this subject's teacher, or school leadership, can send a Home Assignment for it.");
    }

    const referenceCode = generateHomeAssignmentReferenceCode(subjectName);
    const assignmentRef = classRef.collection("homeAssignments").doc();
    await assignmentRef.set({
      title,
      instructions: typeof instructions === "string" ? instructions : "",
      subjectName,
      questions,
      markingKeyTitle: typeof markingKeyTitle === "string" ? markingKeyTitle : "",
      markingKey,
      className: (classData.classGrade as string) ?? "",
      subjectTeacherUid: request.auth.uid,
      subjectTeacherName: (callerMemberSnap.data()?.name as string) ?? "",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      deadlineIso: typeof deadlineIso === "string" ? deadlineIso : null,
      referenceCode,
    });

    const learnerNames = (classData.learnerNames as string[] | undefined) ?? [];
    const contactsSnap = await classRef.collection("guardianContacts").doc("data").get();
    const contacts = (contactsSnap.data()?.contacts ?? []) as GuardianContactInput[];

    let emailsSent = 0;
    let emailsFailed = 0;
    const whatsappRecipients: { name: string; phone: string }[] = [];
    const validAttachment =
      attachment && typeof attachment.filename === "string" && typeof attachment.base64 === "string" ? attachment : null;

    for (let i = 0; i < learnerNames.length && i < MAX_BROADCAST_RECIPIENTS; i++) {
      const contact = contacts[i];
      if (!contact) continue;
      if (contact.email) {
        try {
          const response = await fetch("https://api.brevo.com/v3/smtp/email", {
            method: "POST",
            headers: { "api-key": brevoApiKey.value(), "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({
              sender: { name: "Smart Teacher", email: brevoSenderEmail.value() },
              to: [{ email: contact.email, name: `Guardian of ${learnerNames[i]}` }],
              subject: `Home Assignment: ${title} [${referenceCode}]`,
              htmlContent: `<p>A new Home Assignment (${subjectName}) has been issued.</p>${
                instructions ? `<p>${String(instructions).replace(/\n/g, "<br>")}</p>` : ""
              }<p><strong>Reference code: ${referenceCode}</strong><br>Please keep this reference code in your reply — it's how we match your reply back to this assignment.</p>`,
              ...(validAttachment ? { attachment: [{ name: validAttachment.filename, content: validAttachment.base64 }] } : {}),
            }),
          });
          if (response.ok) {
            emailsSent++;
          } else {
            emailsFailed++;
            console.error("sendHomeAssignmentToClass: Brevo rejected a recipient", contact.email, response.status);
          }
        } catch (err) {
          emailsFailed++;
          console.error("sendHomeAssignmentToClass: network error emailing a guardian", err);
        }
      }
      if (contact.phone) {
        whatsappRecipients.push({ name: learnerNames[i], phone: contact.phone });
      }
    }

    return { assignmentId: assignmentRef.id, referenceCode, emailsSent, emailsFailed, whatsappRecipients };
  }
);

// ---------------------------------------------------------------------
// Home Assignment epic, Stages 8 & 9 (added 2026-09-14) — one function
// records a submission's metadata REGARDLESS of which path it came from
// (Stage 8's in-app pupil submission, or Stage 9's teacher-side bulk
// import of externally-received photos): the CALLER's own claims decide
// which branch applies, and a pupil can never claim someone else's name
// (their `learnerName` is resolved server-side from the real
// `learnerUids` link, never trusted from the request) while a teacher
// importing on a pupil's behalf must name someone real already on the
// roster. Photo bytes themselves are already in Storage by the time this
// runs (see storage.rules) — this only ever receives their paths.
// ---------------------------------------------------------------------

interface RecordHomeAssignmentSubmissionRequest {
  schoolId: string;
  classId: string;
  assignmentId: string;
  photoPaths: string[];
  learnerName?: string;
}

export const recordHomeAssignmentSubmission = onCall<RecordHomeAssignmentSubmissionRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ submissionId: string }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, assignmentId, photoPaths, learnerName } = request.data ?? {};
    if (
      !nonEmptyString(schoolId) ||
      !nonEmptyString(classId) ||
      !nonEmptyString(assignmentId) ||
      !Array.isArray(photoPaths) ||
      photoPaths.length === 0 ||
      !photoPaths.every((p) => typeof p === "string")
    ) {
      throw new HttpsError("invalid-argument", "A school, class, assignment, and at least one photo are required.");
    }

    const db = admin.firestore();
    const classRef = db.collection("schools").doc(schoolId).collection("classes").doc(classId);
    const assignmentRef = classRef.collection("homeAssignments").doc(assignmentId);
    const [classSnap, assignmentSnap] = await Promise.all([classRef.get(), assignmentRef.get()]);
    if (!classSnap.exists || !assignmentSnap.exists) {
      throw new HttpsError("not-found", "That class or assignment could not be found.");
    }
    const classData = classSnap.data()!;

    const token = request.auth.token as Record<string, unknown>;
    const isPupilOfThisClass = token.pupilSchoolId === schoolId && token.pupilClassId === classId;

    let resolvedLearnerName: string;
    let submittedVia: "app" | "imported";

    if (isPupilOfThisClass) {
      const learnerUids = (classData.learnerUids as Record<string, string> | undefined) ?? {};
      const matched = Object.entries(learnerUids).find(([, uid]) => uid === request.auth!.uid);
      if (!matched) {
        throw new HttpsError("failed-precondition", "Your account isn't linked to a specific name on this class's roster yet — ask your teacher to confirm your join request.");
      }
      resolvedLearnerName = matched[0];
      submittedVia = "app";
    } else {
      const callerMemberSnap = await db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get();
      if (!callerMemberSnap.exists) {
        throw new HttpsError("permission-denied", "You are not a member of this school, and this account isn't linked to this class as a pupil either.");
      }
      const callerRole = callerMemberSnap.data()?.role as SchoolRole;
      const isLeadership = LEADERSHIP_ROLES.includes(callerRole) || callerRole === "administrator";
      const assignmentSubject = assignmentSnap.data()?.subjectName as string | undefined;
      const isThisSubjectTeacher = assignmentSubject != null && (classData.subjectTeacherUids ?? {})[assignmentSubject] === request.auth.uid;
      if (!isLeadership && !isThisSubjectTeacher) {
        throw new HttpsError("permission-denied", "Only this assignment's subject teacher, or school leadership, can import a submission.");
      }
      if (!nonEmptyString(learnerName)) {
        throw new HttpsError("invalid-argument", "A learner name is required to import a submission.");
      }
      const trimmedName = learnerName.trim();
      if (!((classData.learnerNames as string[] | undefined) ?? []).includes(trimmedName)) {
        throw new HttpsError("invalid-argument", "That name isn't on this class's roster.");
      }
      resolvedLearnerName = trimmedName;
      submittedVia = "imported";
    }

    const submissionId = await writeHomeAssignmentSubmission(assignmentRef, {
      learnerName: resolvedLearnerName,
      photoPaths,
      submittedVia,
      submittedByUid: request.auth.uid,
    });

    return { submissionId };
  }
);

// Shared by recordHomeAssignmentSubmission (a real signed-in caller — pupil
// or teacher-import) and pollGmailForHomeAssignmentReplies (Stage 2b, no
// caller at all — a scheduled function reading a shared inbox) so both
// ingestion paths write the exact same submission shape. Permission
// checks stay in each caller, not here — this is pure persistence.
async function writeHomeAssignmentSubmission(
  assignmentRef: admin.firestore.DocumentReference,
  data: { learnerName: string; photoPaths: string[]; submittedVia: "app" | "imported" | "email"; submittedByUid: string }
): Promise<string> {
  const submissionRef = assignmentRef.collection("submissions").doc();
  await submissionRef.set({
    learnerName: data.learnerName,
    photoPaths: data.photoPaths,
    submittedVia: data.submittedVia,
    submittedByUid: data.submittedByUid,
    submittedAt: admin.firestore.FieldValue.serverTimestamp(),
    status: "queued",
  });
  return submissionRef.id;
}

// ---------------------------------------------------------------------
// Home Assignment epic, Stage 10 (added 2026-09-14) — records ONE
// submission's marking result. The actual AI grading call itself
// (Concise/Stable Marker) happens CLIENT-SIDE, reusing
// `gradeMarkingScriptConcise` exactly the way Scan Marker already does —
// this function is only the write-back step (submissions have
// `allow write: if false` in firestore.rules, so even the marking
// teacher's own device can't write results directly).
// ---------------------------------------------------------------------

interface HomeAssignmentGradedAnswerInput {
  questionLabel: string;
  transcribedAnswer: string;
  marksAwarded: number;
  maxMarks: number;
  confidence: "high" | "medium" | "low";
}

interface RecordHomeAssignmentMarkingResultRequest {
  schoolId: string;
  classId: string;
  assignmentId: string;
  submissionId: string;
  score: number;
  maxScore: number;
  answers: HomeAssignmentGradedAnswerInput[];
  markingEngine: "concise" | "stable";
}

export const recordHomeAssignmentMarkingResult = onCall<RecordHomeAssignmentMarkingResultRequest>(
  { region: "us-central1", timeoutSeconds: 30, maxInstances: 5 },
  async (request): Promise<{ success: boolean }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, assignmentId, submissionId, score, maxScore, answers, markingEngine } = request.data ?? {};
    if (
      !nonEmptyString(schoolId) ||
      !nonEmptyString(classId) ||
      !nonEmptyString(assignmentId) ||
      !nonEmptyString(submissionId) ||
      typeof score !== "number" ||
      typeof maxScore !== "number" ||
      !Array.isArray(answers) ||
      (markingEngine !== "concise" && markingEngine !== "stable")
    ) {
      throw new HttpsError("invalid-argument", "A school, class, assignment, submission, score, and marking engine are required.");
    }

    const db = admin.firestore();
    const classRef = db.collection("schools").doc(schoolId).collection("classes").doc(classId);
    const assignmentRef = classRef.collection("homeAssignments").doc(assignmentId);
    const [classSnap, assignmentSnap, callerMemberSnap] = await Promise.all([
      classRef.get(),
      assignmentRef.get(),
      db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get(),
    ]);
    if (!classSnap.exists || !assignmentSnap.exists) {
      throw new HttpsError("not-found", "That class or assignment could not be found.");
    }
    if (!callerMemberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const classData = classSnap.data()!;
    const callerRole = callerMemberSnap.data()?.role as SchoolRole;
    const isLeadership = LEADERSHIP_ROLES.includes(callerRole) || callerRole === "administrator";
    const assignmentSubject = assignmentSnap.data()?.subjectName as string | undefined;
    const isThisSubjectTeacher = assignmentSubject != null && (classData.subjectTeacherUids ?? {})[assignmentSubject] === request.auth.uid;
    if (!isLeadership && !isThisSubjectTeacher) {
      throw new HttpsError("permission-denied", "Only this assignment's subject teacher, or school leadership, can record marking results.");
    }

    await assignmentRef.collection("submissions").doc(submissionId).update({
      score,
      maxScore,
      answers,
      markingEngine,
      status: "marked",
      markedAt: admin.firestore.FieldValue.serverTimestamp(),
      markedByUid: request.auth.uid,
    });

    return { success: true };
  }
);

// ---------------------------------------------------------------------
// Home Assignment epic, Stage 11 (added 2026-09-14) — "Batch Review
// before send... one 'Approve & Send Batch' action." Dispatches every
// ALREADY-MARKED submission's result to its learner (guardian email/
// WhatsApp tap-through, same infrastructure as sendHomeAssignmentToClass
// above) and flips each to `status: "sent"`. Never marks anything itself
// — a submission not already `status: "marked"` is skipped, not marked
// on the fly, so this function can never be used to bypass the batch
// review step.
// ---------------------------------------------------------------------

interface SendHomeAssignmentBatchResultsRequest {
  schoolId: string;
  classId: string;
  assignmentId: string;
  submissionIds: string[];
}

export const sendHomeAssignmentBatchResults = onCall<SendHomeAssignmentBatchResultsRequest>(
  { secrets: [brevoApiKey, brevoSenderEmail], region: "us-central1", timeoutSeconds: 180, memory: "256MiB", maxInstances: 5 },
  async (request): Promise<{ sent: number; skipped: number; emailsSent: number; emailsFailed: number; whatsappRecipients: { name: string; phone: string }[] }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, assignmentId, submissionIds } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !nonEmptyString(classId) || !nonEmptyString(assignmentId) || !Array.isArray(submissionIds) || submissionIds.length === 0) {
      throw new HttpsError("invalid-argument", "A school, class, assignment, and at least one submission are required.");
    }

    const db = admin.firestore();
    const classRef = db.collection("schools").doc(schoolId).collection("classes").doc(classId);
    const assignmentRef = classRef.collection("homeAssignments").doc(assignmentId);
    const [classSnap, assignmentSnap, callerMemberSnap] = await Promise.all([
      classRef.get(),
      assignmentRef.get(),
      db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get(),
    ]);
    if (!classSnap.exists || !assignmentSnap.exists) {
      throw new HttpsError("not-found", "That class or assignment could not be found.");
    }
    if (!callerMemberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const classData = classSnap.data()!;
    const assignmentData = assignmentSnap.data()!;
    const callerRole = callerMemberSnap.data()?.role as SchoolRole;
    const isLeadership = LEADERSHIP_ROLES.includes(callerRole) || callerRole === "administrator";
    const isThisSubjectTeacher = (classData.subjectTeacherUids ?? {})[assignmentData.subjectName as string] === request.auth.uid;
    if (!isLeadership && !isThisSubjectTeacher) {
      throw new HttpsError("permission-denied", "Only this assignment's subject teacher, or school leadership, can send batch results.");
    }

    const learnerNames = (classData.learnerNames as string[] | undefined) ?? [];
    const contactsSnap = await classRef.collection("guardianContacts").doc("data").get();
    const contacts = (contactsSnap.data()?.contacts ?? []) as GuardianContactInput[];
    const contactByLearnerName = new Map<string, GuardianContactInput>();
    for (let i = 0; i < learnerNames.length; i++) {
      if (contacts[i]) contactByLearnerName.set(learnerNames[i], contacts[i]);
    }

    let sent = 0;
    let skipped = 0;
    let emailsSent = 0;
    let emailsFailed = 0;
    const whatsappRecipients: { name: string; phone: string }[] = [];

    for (const submissionId of submissionIds.slice(0, MAX_BROADCAST_RECIPIENTS)) {
      const submissionRef = assignmentRef.collection("submissions").doc(submissionId);
      const submissionSnap = await submissionRef.get();
      if (!submissionSnap.exists || submissionSnap.data()?.status !== "marked") {
        skipped++;
        continue;
      }
      const submissionData = submissionSnap.data()!;
      const learnerName = submissionData.learnerName as string;
      const contact = contactByLearnerName.get(learnerName);

      if (contact?.email) {
        try {
          const response = await fetch("https://api.brevo.com/v3/smtp/email", {
            method: "POST",
            headers: { "api-key": brevoApiKey.value(), "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({
              sender: { name: "Smart Teacher", email: brevoSenderEmail.value() },
              to: [{ email: contact.email, name: `Guardian of ${learnerName}` }],
              subject: `Home Assignment result: ${assignmentData.title}`,
              htmlContent: `<p>${learnerName} scored ${submissionData.score} out of ${submissionData.maxScore} on "${assignmentData.title}".</p>`,
            }),
          });
          if (response.ok) emailsSent++;
          else emailsFailed++;
        } catch (err) {
          emailsFailed++;
          console.error("sendHomeAssignmentBatchResults: network error emailing a guardian", err);
        }
      }
      if (contact?.phone) {
        whatsappRecipients.push({ name: learnerName, phone: contact.phone });
      }

      await submissionRef.update({ status: "sent", sentAt: admin.firestore.FieldValue.serverTimestamp() });
      sent++;
    }

    return { sent, skipped, emailsSent, emailsFailed, whatsappRecipients };
  }
);

// ---------------------------------------------------------------------
// Home Assignment epic, Stage 12 (added 2026-09-14) — "reuse the
// Submissions Dashboard's reminder mechanism." That mechanism does not
// actually exist anywhere in this codebase (confirmed before building
// this — teacher_submissions_dashboard_screen.dart's own doc comment
// explicitly lists a per-student "Remind" nudge as deliberately NOT
// built, since that lightweight mailbox model has no real class roster
// to remind against). This is a genuinely new reminder, built the same
// way as everything else in this epic (loop-per-recipient email +
// WhatsApp tap-through) rather than a reuse of something that isn't
// there.
// ---------------------------------------------------------------------

interface RemindHomeAssignmentNonSubmittersRequest {
  schoolId: string;
  classId: string;
  assignmentId: string;
}

export const remindHomeAssignmentNonSubmitters = onCall<RemindHomeAssignmentNonSubmittersRequest>(
  { secrets: [brevoApiKey, brevoSenderEmail], region: "us-central1", timeoutSeconds: 180, memory: "256MiB", maxInstances: 5 },
  async (request): Promise<{ remindedCount: number; emailsSent: number; emailsFailed: number; whatsappRecipients: { name: string; phone: string }[] }> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required.");
    }
    const { schoolId, classId, assignmentId } = request.data ?? {};
    if (!nonEmptyString(schoolId) || !nonEmptyString(classId) || !nonEmptyString(assignmentId)) {
      throw new HttpsError("invalid-argument", "A school, class, and assignment are required.");
    }

    const db = admin.firestore();
    const classRef = db.collection("schools").doc(schoolId).collection("classes").doc(classId);
    const assignmentRef = classRef.collection("homeAssignments").doc(assignmentId);
    const [classSnap, assignmentSnap, callerMemberSnap, submissionsSnap] = await Promise.all([
      classRef.get(),
      assignmentRef.get(),
      db.collection("schools").doc(schoolId).collection("members").doc(request.auth.uid).get(),
      assignmentRef.collection("submissions").get(),
    ]);
    if (!classSnap.exists || !assignmentSnap.exists) {
      throw new HttpsError("not-found", "That class or assignment could not be found.");
    }
    if (!callerMemberSnap.exists) {
      throw new HttpsError("permission-denied", "You are not a member of this school.");
    }
    const classData = classSnap.data()!;
    const assignmentData = assignmentSnap.data()!;
    const callerRole = callerMemberSnap.data()?.role as SchoolRole;
    const isLeadership = LEADERSHIP_ROLES.includes(callerRole) || callerRole === "administrator";
    const isThisSubjectTeacher = (classData.subjectTeacherUids ?? {})[assignmentData.subjectName as string] === request.auth.uid;
    if (!isLeadership && !isThisSubjectTeacher) {
      throw new HttpsError("permission-denied", "Only this assignment's subject teacher, or school leadership, can send reminders.");
    }

    const submittedNames = new Set(submissionsSnap.docs.map((d) => d.data().learnerName as string));
    const learnerNames = ((classData.learnerNames as string[] | undefined) ?? []).filter((n) => !submittedNames.has(n));
    const allLearnerNames = (classData.learnerNames as string[] | undefined) ?? [];
    const contactsSnap = await classRef.collection("guardianContacts").doc("data").get();
    const contacts = (contactsSnap.data()?.contacts ?? []) as GuardianContactInput[];

    let emailsSent = 0;
    let emailsFailed = 0;
    const whatsappRecipients: { name: string; phone: string }[] = [];

    for (const learnerName of learnerNames.slice(0, MAX_BROADCAST_RECIPIENTS)) {
      const index = allLearnerNames.indexOf(learnerName);
      const contact = index >= 0 ? contacts[index] : undefined;
      if (!contact) continue;
      if (contact.email) {
        try {
          const response = await fetch("https://api.brevo.com/v3/smtp/email", {
            method: "POST",
            headers: { "api-key": brevoApiKey.value(), "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({
              sender: { name: "Smart Teacher", email: brevoSenderEmail.value() },
              to: [{ email: contact.email, name: `Guardian of ${learnerName}` }],
              subject: `Reminder: Home Assignment "${assignmentData.title}"`,
              htmlContent: `<p>${learnerName} has not yet submitted the Home Assignment "${assignmentData.title}"${
                assignmentData.deadlineIso ? ` (due ${new Date(assignmentData.deadlineIso).toLocaleDateString()})` : ""
              }.</p>`,
            }),
          });
          if (response.ok) emailsSent++;
          else emailsFailed++;
        } catch (err) {
          emailsFailed++;
          console.error("remindHomeAssignmentNonSubmitters: network error emailing a guardian", err);
        }
      }
      if (contact.phone) {
        whatsappRecipients.push({ name: learnerName, phone: contact.phone });
      }
    }

    return { remindedCount: learnerNames.length, emailsSent, emailsFailed, whatsappRecipients };
  }
);

// ---------------------------------------------------------------------
// Home Assignment reply-ingestion epic, Stage 2b (added 2026-09-16, per
// explicit request) — "Gmail-based polling fallback (zero domain cost)":
// a dedicated Gmail inbox (not yet created — see the three secrets
// below, all deliberately unset until the project owner creates that
// account and provides real OAuth credentials for it) receives replies
// to Home Assignments the same way any other reply-to email would.
// Every 10 minutes, this scheduled function reads its unread mail,
// extracts each message's Stage 1 reference code, matches the sender
// against the matching class's own `guardianContacts` (the ONLY email
// address this app has on file for any learner — see this function's
// own note on why "match the sender against the roster" really means
// "match against a guardian's email", not a pupil's own, since no pupil
// email field exists anywhere in this app), downloads image attachments,
// and queues them into the exact same `submissions` shape Stage 3's
// real-time webhook (or any other future ingestion path) would produce
// — `writeHomeAssignmentSubmission` is the single shared write path.
// Anything that can't be resolved (no reference code, an unrecognized
// code, or a sender email not on file for that class) is written to
// `unmatchedHomeAssignmentSubmissions` for manual review rather than
// silently dropped, per the brief's own explicit fallback requirement.
//
// This function deploys safely with these secrets unset — it simply logs
// and returns early every run until real values exist. Once the project
// owner creates the Gmail account, enables the Gmail API on it, and
// completes Google's OAuth consent flow for it (a real sign-in action
// only they can do), set the three secrets below via
// `firebase functions:secrets:set GMAIL_CLIENT_ID` etc. — no code change
// needed at that point.
// ---------------------------------------------------------------------

const gmailClientId = defineSecret("GMAIL_CLIENT_ID");
const gmailClientSecret = defineSecret("GMAIL_CLIENT_SECRET");
const gmailRefreshToken = defineSecret("GMAIL_REFRESH_TOKEN");

const HOME_ASSIGNMENT_REFERENCE_CODE_PATTERN = /HA-[A-Z]+-\d{6}-[A-Z0-9]{2}/;

function extractHomeAssignmentReferenceCode(text: string): string | null {
  const match = text.match(HOME_ASSIGNMENT_REFERENCE_CODE_PATTERN);
  return match ? match[0] : null;
}

// "Name <email@example.com>" or a bare address — Gmail's own `From`
// header format varies by client, this covers both.
function extractSenderEmailAddress(fromHeader: string): string | null {
  const angleMatch = fromHeader.match(/<([^>]+)>/);
  const candidate = (angleMatch ? angleMatch[1] : fromHeader).trim();
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(candidate) ? candidate.toLowerCase() : null;
}

interface GmailAttachmentPart {
  filename: string;
  mimeType: string;
  attachmentId: string;
}

// Gmail's MIME structure is a recursive `parts` tree (a multipart/mixed
// message has multipart/alternative + attachment parts as siblings, and
// so on) — this walks the whole tree once, collecting only real image
// attachments (a signature image, an emoji, or a forwarded logo isn't a
// scanned assignment page).
function collectImageAttachmentParts(part: Record<string, unknown> | undefined, out: GmailAttachmentPart[] = []): GmailAttachmentPart[] {
  if (!part) return out;
  const filename = part.filename as string | undefined;
  const mimeType = part.mimeType as string | undefined;
  const body = part.body as Record<string, unknown> | undefined;
  const attachmentId = body?.attachmentId as string | undefined;
  if (filename && attachmentId && mimeType?.startsWith("image/")) {
    out.push({ filename, mimeType, attachmentId });
  }
  const children = part.parts as Record<string, unknown>[] | undefined;
  if (Array.isArray(children)) {
    for (const child of children) collectImageAttachmentParts(child, out);
  }
  return out;
}

async function getGmailAccessToken(): Promise<string> {
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: gmailClientId.value(),
      client_secret: gmailClientSecret.value(),
      refresh_token: gmailRefreshToken.value(),
      grant_type: "refresh_token",
    }).toString(),
  });
  if (!response.ok) {
    throw new Error(`Gmail OAuth token refresh failed: ${response.status} ${await response.text()}`);
  }
  const json = (await response.json()) as { access_token: string };
  return json.access_token;
}

async function gmailApiGet(path: string, accessToken: string): Promise<any> {
  const response = await fetch(`https://www.googleapis.com/gmail/v1${path}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!response.ok) {
    throw new Error(`Gmail API GET ${path} failed: ${response.status} ${await response.text()}`);
  }
  return response.json();
}

async function markGmailMessageRead(messageId: string, accessToken: string): Promise<void> {
  await fetch(`https://www.googleapis.com/gmail/v1/users/me/messages/${messageId}/modify`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ removeLabelIds: ["UNREAD"] }),
  });
}

interface UnmatchedHomeAssignmentSubmissionRecord {
  reason: "no-reference-code" | "unknown-reference-code" | "sender-not-on-roster" | "no-attachments";
  gmailMessageId: string;
  subject: string;
  senderEmail: string | null;
  referenceCode?: string;
  schoolId?: string;
  classId?: string;
  assignmentId?: string;
  learnerName?: string;
}

async function recordUnmatchedHomeAssignmentSubmission(record: UnmatchedHomeAssignmentSubmissionRecord): Promise<void> {
  await admin.firestore().collection("unmatchedHomeAssignmentSubmissions").add({
    ...record,
    receivedAt: admin.firestore.FieldValue.serverTimestamp(),
    resolved: false,
  });
}

export const pollGmailForHomeAssignmentReplies = onSchedule(
  { schedule: "every 10 minutes", secrets: [gmailClientId, gmailClientSecret, gmailRefreshToken], region: "us-central1", timeoutSeconds: 300, memory: "256MiB" },
  async () => {
    let clientId: string, clientSecret: string, refreshToken: string;
    try {
      clientId = gmailClientId.value();
      clientSecret = gmailClientSecret.value();
      refreshToken = gmailRefreshToken.value();
    } catch {
      clientId = clientSecret = refreshToken = "";
    }
    if (!clientId || !clientSecret || !refreshToken) {
      // Not configured yet — the dedicated Gmail account doesn't exist
      // yet, or its credentials haven't been set. Deliberately a no-op,
      // not an error: this function is meant to deploy and sit idle
      // until real values exist, per this epic's own Stage 2b framing.
      console.log("pollGmailForHomeAssignmentReplies: Gmail credentials not configured yet — skipping this run.");
      return;
    }

    const accessToken = await getGmailAccessToken();
    const listing = await gmailApiGet("/users/me/messages?q=is:unread&maxResults=25", accessToken);
    const messageRefs = (listing.messages as { id: string }[] | undefined) ?? [];

    for (const { id: messageId } of messageRefs) {
      try {
        const message = await gmailApiGet(`/users/me/messages/${messageId}?format=full`, accessToken);
        const headers = (message.payload?.headers as { name: string; value: string }[] | undefined) ?? [];
        const subject = headers.find((h) => h.name.toLowerCase() === "subject")?.value ?? "";
        const fromHeader = headers.find((h) => h.name.toLowerCase() === "from")?.value ?? "";
        const senderEmail = extractSenderEmailAddress(fromHeader);
        const referenceCode = extractHomeAssignmentReferenceCode(subject) ?? extractHomeAssignmentReferenceCode((message.snippet as string | undefined) ?? "");

        if (!referenceCode) {
          await recordUnmatchedHomeAssignmentSubmission({ reason: "no-reference-code", gmailMessageId: messageId, subject, senderEmail });
          await markGmailMessageRead(messageId, accessToken);
          continue;
        }

        const assignmentQuery = await admin
          .firestore()
          .collectionGroup("homeAssignments")
          .where("referenceCode", "==", referenceCode)
          .limit(1)
          .get();
        if (assignmentQuery.empty) {
          await recordUnmatchedHomeAssignmentSubmission({ reason: "unknown-reference-code", gmailMessageId: messageId, subject, senderEmail, referenceCode });
          await markGmailMessageRead(messageId, accessToken);
          continue;
        }

        const assignmentRef = assignmentQuery.docs[0].ref;
        const classRef = assignmentRef.parent.parent!;
        const schoolRef = classRef.parent.parent!;
        const classSnap = await classRef.get();
        const classData = classSnap.data() ?? {};
        const learnerNames = (classData.learnerNames as string[] | undefined) ?? [];
        const contactsSnap = await classRef.collection("guardianContacts").doc("data").get();
        const contacts = (contactsSnap.data()?.contacts ?? []) as GuardianContactInput[];
        const matchedIndex = senderEmail
          ? contacts.findIndex((c) => c?.email && c.email.toLowerCase() === senderEmail)
          : -1;

        if (matchedIndex === -1 || !learnerNames[matchedIndex]) {
          await recordUnmatchedHomeAssignmentSubmission({
            reason: "sender-not-on-roster",
            gmailMessageId: messageId,
            subject,
            senderEmail,
            referenceCode,
            schoolId: schoolRef.id,
            classId: classRef.id,
            assignmentId: assignmentRef.id,
          });
          await markGmailMessageRead(messageId, accessToken);
          continue;
        }
        const learnerName = learnerNames[matchedIndex];

        const attachmentParts = collectImageAttachmentParts(message.payload as Record<string, unknown> | undefined);
        if (attachmentParts.length === 0) {
          await recordUnmatchedHomeAssignmentSubmission({
            reason: "no-attachments",
            gmailMessageId: messageId,
            subject,
            senderEmail,
            referenceCode,
            schoolId: schoolRef.id,
            classId: classRef.id,
            assignmentId: assignmentRef.id,
            learnerName,
          });
          await markGmailMessageRead(messageId, accessToken);
          continue;
        }

        const bucket = admin.storage().bucket();
        const photoPaths: string[] = [];
        for (let i = 0; i < attachmentParts.length; i++) {
          const part = attachmentParts[i];
          const attachment = await gmailApiGet(`/users/me/messages/${messageId}/attachments/${part.attachmentId}`, accessToken);
          const buffer = Buffer.from(attachment.data as string, "base64url");
          const storagePath = `schools/${schoolRef.id}/classes/${classRef.id}/homeAssignments/${assignmentRef.id}/submissions/email-${messageId}/page_${i}.jpg`;
          await bucket.file(storagePath).save(buffer, { contentType: part.mimeType });
          photoPaths.push(storagePath);
        }

        await writeHomeAssignmentSubmission(assignmentRef, {
          learnerName,
          photoPaths,
          submittedVia: "email",
          submittedByUid: "system:gmail-poll",
        });
        await markGmailMessageRead(messageId, accessToken);
      } catch (err) {
        // One malformed/unusual message should never abort the whole
        // poll — log it and move on to the next; it stays unread, so
        // it's retried next run rather than silently lost.
        console.error(`pollGmailForHomeAssignmentReplies: failed to process message ${messageId}`, err);
      }
    }
  }
);
