import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import Anthropic from "@anthropic-ai/sdk";

// Stored via `firebase functions:secrets:set ANTHROPIC_API_KEY` — never in
// app code or committed config. See firebase/README.md for setup.
const anthropicApiKey = defineSecret("ANTHROPIC_API_KEY");

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

  return [
    "Write 600-750 words of teaching notes for a teacher preparing a lesson.",
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
  ]
    .filter((line): line is string => line !== null)
    .join("\n");
}

export const generateTeachingNotes = onCall<GenerateTeachingNotesRequest>(
  { secrets: [anthropicApiKey], region: "us-central1" },
  async (request): Promise<GenerateTeachingNotesResponse> => {
    // Callable functions verify the Firebase Auth ID token automatically —
    // request.auth is only populated for requests carrying a valid token
    // from THIS Firebase project, which is what keeps arbitrary callers off
    // the function (and off the Anthropic API budget behind it).
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

    const client = new Anthropic({ apiKey: anthropicApiKey.value() });
    const req: GenerateTeachingNotesRequest = { topic, subtopic, syllabusContext, format };

    let response;
    try {
      response = await client.messages.create({
        model: "claude-opus-5",
        max_tokens: 2048,
        messages: [{ role: "user", content: buildPrompt(req) }],
      });
    } catch (err) {
      console.error("Anthropic API call failed", err);
      throw new HttpsError("internal", "Failed to generate teaching notes. Please try again.");
    }

    if (response.stop_reason === "refusal") {
      throw new HttpsError(
        "failed-precondition",
        "The request was declined. Try rephrasing the topic or syllabus context."
      );
    }

    const textBlock = response.content.find(
      (block): block is Anthropic.TextBlock => block.type === "text"
    );
    if (!textBlock) {
      throw new HttpsError("internal", "The AI did not return any text.");
    }

    return {
      notes: textBlock.text,
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
        },
        required: ["title", "url", "subjectName", "level", "term"],
        additionalProperties: false,
      },
    },
  },
  required: ["resources"],
  additionalProperties: false,
};

const CDC_CATALOG_PROMPT = [
  "Catalog official Zambian Curriculum Development Centre (CDC) 'Teaching Module' " +
    "documents so a teacher-facing app can list them for download.",
  "",
  "Search and browse https://library.cdcrepository.info/ (its browse.php?level=ece, " +
    "?level=primary, and ?level=secondary listing pages, and their pagination) to find " +
    "as many individual Teaching Module resources as you reasonably can within your " +
    "tool-call budget. For each one, record: the exact title as listed, the subject name, " +
    "the grade/level/form it's for, the term if stated, and the direct resource page URL " +
    "(the resource.php?id=... page, not the download link).",
  "",
  "Prioritize breadth (covering many subjects and levels) over exhaustively listing every " +
    "single resource on the site — this catalog will be refreshed periodically, so a good " +
    "partial pass now is fine.",
  "",
  "Only include resources you actually found on the site. Do not invent titles, subjects, " +
    "or URLs. If you cannot access the site, return an empty resources array rather than " +
    "guessing.",
].join("\n");

export const listCdcResources = onCall<Record<string, never>>(
  { secrets: [anthropicApiKey], region: "us-central1", timeoutSeconds: 300, memory: "512MiB" },
  async (request): Promise<ListCdcResourcesResponse> => {
    // Same auth gate as generateTeachingNotes — this still spends API
    // budget (web search/fetch + generation), so only signed-in app clients
    // may call it.
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in is required to fetch CDC resources.");
    }

    const client = new Anthropic({ apiKey: anthropicApiKey.value() });

    const tools: Anthropic.Messages.ToolUnion[] = [
      { type: "web_search_20260318", name: "web_search", max_uses: 20 },
      {
        type: "web_fetch_20260318",
        name: "web_fetch",
        max_uses: 25,
        allowed_domains: ["library.cdcrepository.info"],
      },
    ];
    const outputConfig = { format: { type: "json_schema" as const, schema: cdcResourcesSchema } };

    let messages: Anthropic.Messages.MessageParam[] = [{ role: "user", content: CDC_CATALOG_PROMPT }];
    let response;
    let resumes = 0;

    try {
      response = await client.messages.create({
        model: "claude-opus-5",
        max_tokens: 8000,
        tools,
        output_config: outputConfig,
        messages,
      });

      // Server-side tool loops (web_search/web_fetch) can hit their default
      // iteration cap mid-crawl; resend to resume rather than returning a
      // truncated catalog. Capped so one call can't run away.
      while (response.stop_reason === "pause_turn" && resumes < 3) {
        messages = [
          { role: "user", content: CDC_CATALOG_PROMPT },
          { role: "assistant", content: response.content },
        ];
        response = await client.messages.create({
          model: "claude-opus-5",
          max_tokens: 8000,
          tools,
          output_config: outputConfig,
          messages,
        });
        resumes += 1;
      }
    } catch (err) {
      console.error("CDC catalog fetch failed", err);
      throw new HttpsError("internal", "Failed to fetch the CDC catalog. Please try again.");
    }

    if (response.stop_reason === "refusal") {
      throw new HttpsError("failed-precondition", "The catalog request was declined.");
    }

    const textBlock = response.content.find(
      (block): block is Anthropic.TextBlock => block.type === "text"
    );
    if (!textBlock) {
      throw new HttpsError("internal", "No catalog data was returned.");
    }

    let parsed: { resources?: CdcResource[] };
    try {
      parsed = JSON.parse(textBlock.text);
    } catch (err) {
      console.error("CDC catalog response was not valid JSON", textBlock.text);
      throw new HttpsError("internal", "The catalog response could not be parsed.");
    }

    return {
      resources: parsed.resources ?? [],
      fetchedAt: new Date().toISOString(),
    };
  }
);
