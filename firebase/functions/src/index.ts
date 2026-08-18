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
