import Anthropic from "@anthropic-ai/sdk";
import { getAccountKeys, getPlatformKeys } from "@/lib/db";
import { resolveEntitlement } from "@/lib/appauth";
import { pick } from "@/lib/router";
import { floorTierFor, resolveTier, type Tier } from "@/lib/tiers";

/**
 * Utterance → structured Task (SPEC.md §5.1 step 4). One short model call
 * chosen by the router, with a deterministic fallback so the pipeline works
 * with no key at all (tests, first run, provider outage). The model's tier is
 * only ever raised by the deterministic floor, never lowered.
 */

export type Capability =
  | "draft_copy"
  | "research"
  | "code"
  | "screen_action"
  | "call"
  | "email"
  | "schedule"
  | "purchase"
  | "other";

export const CAPABILITIES: readonly Capability[] = [
  "draft_copy", "research", "code", "screen_action", "call", "email", "schedule", "purchase", "other",
];

export type Intent = "question" | "task" | "decision" | "note" | "smalltalk";

export interface Extraction {
  intent: Intent;
  title: string;
  detail: string;
  capability: Capability;
  /** Tier the action in the world will need (draft = 0, publish = 2, pay = 3). */
  blast_tier: Tier;
  /** Who the user named as the doer, if anyone ("have Alex…", "the content agent"). */
  named_owner: string | null;
  /** Free-text due phrase ("by 3", "Friday"), unparsed in Phase 0. */
  due_phrase: string | null;
  /** How we got here — on every receipt. */
  model_used: string | null;
}

const SYSTEM = `You turn one spoken request from a busy founder into a structured task for a chief-of-staff system.
Rules:
- intent: "task" when they want something done; "question" when they want an answer; "decision" when they are recording a choice; "note" when they are just capturing; "smalltalk" otherwise.
- title: imperative, under 12 words, no trailing period.
- detail: everything else needed to do it well, in their words, at most 3 sentences.
- capability: the ONE kind of work the doer needs: draft_copy (writing), research, code, screen_action (clicking around apps/sites), call (phone), email, schedule (calendar), purchase (spending money), other.
- blast_tier: 0 = internal only (drafts, research, summaries); 1 = reversible external with no money (reservations, calendar holds); 2 = public or team-facing (publish, post, email a teammate); 3 = money or a commitment to a third party (pay, hire, email a client, commit a vendor); 4 = irreversible (delete data, cancel a contract). Tier the action the request will eventually take in the world, not the drafting step. "Draft a post and bring it to me" is 0; "post it" is 2.
- named_owner: the person or agent they named to do it, else null.
- due_phrase: the time phrase they used, verbatim, else null.
Never invent detail they did not say.`;

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["intent", "title", "detail", "capability", "blast_tier", "named_owner", "due_phrase"],
  properties: {
    intent: { type: "string", enum: ["question", "task", "decision", "note", "smalltalk"] },
    title: { type: "string" },
    detail: { type: "string" },
    capability: { type: "string", enum: [...CAPABILITIES] },
    blast_tier: { type: "integer", minimum: 0, maximum: 4 },
    named_owner: { type: ["string", "null"] },
    due_phrase: { type: ["string", "null"] },
  },
} as const;

/** The Anthropic key this account runs on — same resolution as /api/app/keys:
 *  platform key for Cloud plans, the account's own key for BYOK. Env override
 *  for local dev and the demo script. */
export async function anthropicKeyFor(email: string): Promise<string | null> {
  if (process.env.ANTHROPIC_API_KEY) return process.env.ANTHROPIC_API_KEY;
  const ent = await resolveEntitlement(email).catch(() => null);
  if (ent?.mode === "cloud") return (await getPlatformKeys()).anthropic;
  return (await getAccountKeys(email)).anthropic;
}

export async function extractTask(email: string, text: string): Promise<Extraction> {
  const key = await anthropicKeyFor(email);
  const route = await pick("task_extract");
  if (!key || !route || route.provider !== "anthropic") return fallbackExtract(text, null);

  const client = new Anthropic({ apiKey: key });
  try {
    const res = await client.messages.create({
      model: route.model,
      max_tokens: 1024,
      system: SYSTEM,
      messages: [{ role: "user", content: text }],
      output_config: {
        format: { type: "json_schema", schema: SCHEMA },
        ...(route.options.effort ? { effort: route.options.effort as "low" | "medium" | "high" } : {}),
      },
    });
    const block = res.content.find((b) => b.type === "text");
    if (!block || block.type !== "text") return fallbackExtract(text, route.model);
    const parsed = JSON.parse(block.text) as Omit<Extraction, "model_used" | "blast_tier"> & { blast_tier: number };
    return {
      intent: parsed.intent,
      title: parsed.title || text.slice(0, 80),
      detail: parsed.detail ?? "",
      capability: CAPABILITIES.includes(parsed.capability) ? parsed.capability : "other",
      blast_tier: resolveTier(text, parsed.blast_tier),
      named_owner: parsed.named_owner ?? null,
      due_phrase: parsed.due_phrase ?? null,
      model_used: route.model,
    };
  } catch (e) {
    // A model hiccup must not lose the request: fall through to the rules.
    console.warn("[extract] model call failed, using fallback:", e instanceof Error ? e.message : e);
    return fallbackExtract(text, null);
  }
}

const CAP_RULES: [RegExp, Capability][] = [
  [/\b(draft|write|blog|post|copy|caption|newsletter|script|tweet|article)\b/i, "draft_copy"],
  [/\b(research|look into|find out|compare|investigate|summari[sz]e)\b/i, "research"],
  [/\b(code|bug|deploy|repo|function|implement|refactor|pull request)\b/i, "code"],
  [/\b(call|phone|ring)\b/i, "call"],
  [/\b(email|e-mail|mail)\b/i, "email"],
  [/\b(schedule|calendar|meeting|book (a )?(time|slot|meeting)|reschedule)\b/i, "schedule"],
  [/\b(buy|pay|purchase|order|subscribe)\b/i, "purchase"],
  [/\b(open|click|type|scroll|press|tab|window|paste)\b/i, "screen_action"],
];

const OWNER_RULES = /\b(?:have|ask|tell|get)\s+(?:the\s+)?([a-z][a-z-]*(?:\s+(?:agent|drafter|researcher|engineer|writer))?)\s+(?:to\s+)?(?:draft|write|research|do|handle|look|find|build|make|send|call)/i;

/** Deterministic extraction. Good enough to keep the demo honest without a key. */
export function fallbackExtract(text: string, modelUsed: string | null): Extraction {
  const t = text.trim();
  const cap = CAP_RULES.find(([re]) => re.test(t))?.[1] ?? "other";
  const owner = OWNER_RULES.exec(t)?.[1]?.trim() ?? null;
  const due = /\b(by|before|until|at)\s+([0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)?|noon|tonight|tomorrow|today|monday|tuesday|wednesday|thursday|friday|saturday|sunday|end of (?:day|week))\b/i.exec(t);
  const intent: Intent = /^(what|who|when|where|why|how|is|are|do|does|can|could|should)\b/i.test(t) && !/\b(draft|write|make|build|send)\b/i.test(t)
    ? "question"
    : "task";
  // Title: the first clause, minus politeness and the "have X do…" delegation
  // wrapper (the owner is recorded separately), cut at a word boundary.
  const title = titleFrom(t);
  return {
    intent,
    title: title || t.slice(0, 80),
    detail: t,
    capability: cap,
    blast_tier: floorTierFor(t),
    named_owner: owner,
    due_phrase: due ? due[0] : null,
    model_used: modelUsed,
  };
}

export function titleFrom(text: string, max = 80): string {
  let t = text.trim()
    .replace(/^(please|hey|ok|okay|can you|could you|i want you to|i need you to|i'd like you to)\s+/i, "")
    .replace(/^(?:have|ask|tell|get)\s+(?:the\s+)?[a-z][a-z-]*(?:\s+(?:agent|drafter|researcher|engineer|writer))?\s+(?:to\s+)?/i, "")
    .split(/[.;\n]|,? and (?:then )?bring/i)[0]
    .replace(/,?\s+and\s+(?:post|publish|send|email|share)\s+(?:it|this|that)\b.*$/i, "")
    .trim();
  if (t.length > max) {
    const cut = t.slice(0, max);
    t = (cut.lastIndexOf(" ") > max / 2 ? cut.slice(0, cut.lastIndexOf(" ")) : cut) + "…";
  }
  return t.replace(/^./, (c) => c.toUpperCase());
}
