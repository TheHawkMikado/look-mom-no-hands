import Anthropic from "@anthropic-ai/sdk";
import { anthropicKeyFor } from "@/lib/extract";
import { pick } from "@/lib/router";

/**
 * Dictation → structured note report (title, summary, key points, action
 * items) for the phone's Notes tab. Same prompt and schema the Mac app uses
 * for its own dictation reports (ClaudeClient.reportRequestBody), so a note
 * reads the same whichever device captured it. Runs on the account's key via
 * the router's summarize route; the transcript is never echoed back — the
 * phone already holds it.
 */

export interface NoteReport {
  title: string;
  summary: string;
  keyPoints: string[];
  actionItems: string[];
}

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["title", "summary", "key_points", "action_items"],
  properties: {
    title: { type: "string" },
    summary: { type: "string" },
    key_points: { type: "array", items: { type: "string" } },
    action_items: { type: "array", items: { type: "string" } },
  },
} as const;

function prompt(transcript: string): string {
  return `Turn this raw dictation into a structured report:
- title: a short (3-8 word) headline naming what this note is about.
- summary: a tight TLDR (1-3 sentences).
- key_points: the main ideas as short bullets (empty if none).
- action_items: concrete to-dos as short bullets (empty if none).
Do not repeat the transcript back.

Dictation:
${transcript}`;
}

const strings = (v: unknown): string[] =>
  Array.isArray(v) ? v.filter((s): s is string => typeof s === "string" && s.trim() !== "") : [];

/** Tolerant like the Mac's decoder: a missing field degrades, never throws. */
export function parseReport(raw: unknown): NoteReport {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  return {
    title: typeof r.title === "string" ? r.title.trim() : "",
    summary: typeof r.summary === "string" ? r.summary.trim() : "",
    keyPoints: strings(r.key_points),
    actionItems: strings(r.action_items),
  };
}

/** Null when the account has no Anthropic key to run on. */
export async function reportForNote(email: string, text: string): Promise<NoteReport | null> {
  const key = await anthropicKeyFor(email);
  if (!key) return null;
  const route = await pick("summarize_meeting");
  const model = route && route.provider === "anthropic" ? route.model : "claude-opus-5";
  const effort = route?.options?.effort;
  const client = new Anthropic({ apiKey: key });
  const res = await client.messages.create({
    model,
    max_tokens: 2048,
    messages: [{ role: "user", content: prompt(text) }],
    output_config: {
      format: { type: "json_schema", schema: SCHEMA },
      ...(effort ? { effort: effort as "low" | "medium" | "high" } : {}),
    },
  });
  const block = res.content.find((b) => b.type === "text");
  if (!block || block.type !== "text") throw new Error("no text block in report response");
  return parseReport(JSON.parse(block.text));
}
