import Anthropic from "@anthropic-ai/sdk";
import { createHash } from "node:crypto";
import { sql } from "@/lib/db";
import { ensureBrainSchema } from "@/lib/db-brain";
import { pick } from "@/lib/router";
import { assertCloudWritable, capCloudText, type Residency } from "@/lib/residency";

/**
 * Shared Brain promotion pipeline (SPEC.md §8.2–8.3):
 *
 *   classifier flags generic learnings → scrubber replaces specifics → user
 *   asked once (default no) → review queue → versioned publish attributable
 *   to a source user hash only.
 *
 * Two hard rules, both unit-tested:
 *  - `scrub` is deterministic and runs on EVERY insert path. There is no
 *    function in this module that writes a candidate without scrubbing it,
 *    so an email or a phone number can never be stored raw.
 *  - The classifier's heuristics decide alone when they are certain; the
 *    `promotion_classify` model (when a key exists) only breaks the
 *    uncertain middle, and it sees scrubbed text only.
 */

export type CandidateKind = "sop" | "website_flow" | "checklist" | "other";
export const CANDIDATE_KINDS: readonly CandidateKind[] = ["sop", "website_flow", "checklist", "other"];

export type PromotionStatus = "pending_consent" | "awaiting_review" | "approved" | "rejected" | "published";

export interface Candidate {
  kind: CandidateKind;
  title: string;
  body: string;
  /** What the scrubber replaced, by placeholder — counts only, never values. */
  scrubbed: Record<string, number>;
  reasons: string[];
}

export interface PromotionRow {
  id: string;
  email: string;
  candidate: Candidate;
  status: PromotionStatus;
  consent_at: Date | null;
  reviewed_at: Date | null;
  sop_id: string | null;
  residency: Residency;
  created_at: Date;
}

export interface SopRow {
  id: string;
  title: string;
  body: string;
  version: number;
  source_user_hash: string;
  published_at: Date;
  residency: Residency;
}

// MARK: - Scrubber

const MONTHS = "(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)";
const STREET = "(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Court|Ct|Way|Place|Pl|Terrace|Ter|Circle|Cir|Highway|Hwy|Parkway|Pkwy)";

/** Ordered: each rule runs on the output of the previous one, so emails and
 *  URLs go before phones (digits inside them), addresses before dates (zip
 *  codes), and names last (placeholders never look like names). */
const RULES: { tag: string; re: RegExp; to: string | ((m: string, ...g: string[]) => string) }[] = [
  { tag: "email", re: /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g, to: "[email]" },
  { tag: "url", re: /\b(?:https?:\/\/|www\.)[^\s<>()"']*[^\s<>()"'.,;:!?]/gi, to: (m) => scrubUrl(m) },
  { tag: "card", re: /\b(?:\d[ -]?){13,19}\b/g, to: "[card]" },
  { tag: "ssn", re: /\b\d{3}-\d{2}-\d{4}\b/g, to: "[id]" },
  {
    tag: "address",
    re: new RegExp(`\\b\\d{1,6}\\s+(?:[A-Z][a-zA-Z]*\\.?\\s+){1,3}${STREET}\\b\\.?(?:,?\\s*(?:Apt|Apartment|Suite|Ste|Unit|#)\\.?\\s*[\\w-]+)?(?:,\\s*[A-Z][a-zA-Z]+(?:\\s[A-Z][a-zA-Z]+)?(?:,\\s*[A-Z]{2})?(?:\\s+\\d{5}(?:-\\d{4})?)?)?`, "g"),
    to: "[address]",
  },
  { tag: "phone", re: /(?:\+\d{1,3}[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b|\+\d[\d\s().-]{7,}\d/g, to: "[phone]" },
  { tag: "amount", re: /\$\s?\d[\d,]*(?:\.\d+)?(?:\s?[kKmM]\b)?|\b\d[\d,]*(?:\.\d+)?\s?(?:dollars|USD|bucks)\b/g, to: "[amount]" },
  { tag: "date", re: /\b\d{4}-\d{2}-\d{2}(?:T[\d:.]+Z?)?\b/g, to: "[date]" },
  { tag: "date", re: /\b\d{1,2}\/\d{1,2}\/\d{2,4}\b/g, to: "[date]" },
  { tag: "date", re: new RegExp(`\\b${MONTHS}\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s+\\d{4})?\\b`, "g"), to: "[date]" },
  { tag: "date", re: new RegExp(`\\b\\d{1,2}(?:st|nd|rd|th)?\\s+(?:of\\s+)?${MONTHS}\\b(?:,?\\s+\\d{4})?`, "g"), to: "[date]" },
  // Names: a capitalised word (or two) after the phrases that introduce a
  // person. Conservative on purpose — "for Google Ads" loses "Google" and
  // the SOP still reads.
  {
    tag: "name",
    re: /\b(I'm|I am|my name is|with|for|from|named|called|thanks to|meet|met|tell|ask|email|text|call|cc|hi|hello|dear)\s+((?:Mr|Mrs|Ms|Dr|Miss)\.?\s+)?([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)(?![a-z])/g,
    to: (_m, lead) => `${lead} [name]`,
  },
  { tag: "name", re: /\b(?:Mr|Mrs|Ms|Dr|Miss)\.?\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?/g, to: "[name]" },
];

function scrubUrl(u: string): string {
  const [head, query] = u.split(/[?#]/, 2);
  const path = head.replace(/\/([^/]+)/g, (seg, part: string) =>
    /\d{4,}|^[0-9a-f]{8}-[0-9a-f]{4}|^[0-9a-f]{12,}$|^(?=.*\d)(?=.*[a-zA-Z])[\w-]{12,}$/i.test(part) ? "/[id]" : seg,
  );
  return query !== undefined ? `${path}?[params]` : path;
}

/** Deterministic scrubber. Same input → same output; placeholder counts
 *  returned so the reviewer can see what was removed without seeing it. */
export function scrub(text: string): { text: string; replacements: Record<string, number> } {
  const replacements: Record<string, number> = {};
  let out = text;
  for (const r of RULES) {
    out = out.replace(r.re, (...args: unknown[]) => {
      replacements[r.tag] = (replacements[r.tag] ?? 0) + 1;
      return typeof r.to === "string" ? r.to : r.to(...(args as [string, ...string[]]));
    });
  }
  return { text: out, replacements };
}

/** Anything the scrubber should have caught. Used by the insert path as a
 *  last line of defence and by the tests. */
export const RAW_PII = /[\w.+-]+@[\w-]+\.[\w-]+|\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b/;

// MARK: - Classifier

const PROCESS = [
  /\b(?:step \d|steps?|first|then|next|after that|finally|lastly)\b/i,
  /\b(?:always|every time|whenever|each (?:week|day|month|morning|time)|weekly|daily|monthly)\b/i,
  /\b(?:checklist|process|workflow|procedure|how to|sop|playbook|template|routine|rule of thumb)\b/i,
  /\b(?:go to|open|click|navigate|log ?in|select|upload|paste|submit|fill (?:in|out)|scroll|export|import|toggle)\b/i,
  /^\s*(?:\d+[.)]|[-*•])\s+/m,
];
const PERSONAL = [
  /\b(?:my|our) (?:wife|husband|partner|kids?|son|daughter|mom|mother|dad|father|doctor|therapist|lawyer|accountant|home|house|apartment|address|phone|birthday|salary|ssn|social security|bank|account|card|health|diagnosis|medication|password)\b/i,
  /\bI (?:live|was born|paid|owe|earn|make|got married|divorced|feel|felt|hate|love|am \d+|weigh|take)\b/i,
  /\b(?:my name is|i'm called|net worth|password|pin code|date of birth)\b/i,
];

export interface Classification {
  generic: boolean;
  /** True when the heuristics alone decide; false = the model may break it. */
  certain: boolean;
  reasons: string[];
}

/** Deterministic heuristics: a repeatable process or website flow with no
 *  first-person facts is generic. Pure. */
export function classifyHeuristic(text: string): Classification {
  const reasons: string[] = [];
  const personal = PERSONAL.filter((re) => re.test(text));
  if (personal.length) {
    reasons.push("first-person facts about the user's life");
    return { generic: false, certain: true, reasons };
  }
  const signals = PROCESS.filter((re) => re.test(text)).length;
  if (signals >= 2) reasons.push(`repeatable process (${signals} signals)`);
  else if (signals === 1) reasons.push("one process signal — borderline");
  else reasons.push("no process or flow signals");
  if (text.trim().length < 40) {
    reasons.push("too short to be a procedure");
    return { generic: false, certain: true, reasons };
  }
  return { generic: signals >= 2, certain: signals !== 1, reasons };
}

const CLASSIFY_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["generic", "reason"],
  properties: { generic: { type: "boolean" }, reason: { type: "string" } },
} as const;

/**
 * Classify a (scrubbed) candidate. Heuristics first; when they are unsure and
 * a key exists, the `promotion_classify` route breaks the tie. No key → the
 * heuristic answer stands (borderline = not generic; default no).
 */
export async function classifyCandidate(text: string, opts: { key?: string | null } = {}): Promise<Classification> {
  const h = classifyHeuristic(text);
  if (h.certain) return h;
  const key = opts.key === undefined ? (process.env.ANTHROPIC_API_KEY ?? null) : opts.key;
  if (!key) return h;
  const route = await pick("promotion_classify").catch(() => null);
  if (!route || route.provider !== "anthropic") return h;
  try {
    const client = new Anthropic({ apiKey: key });
    const res = await client.messages.create({
      model: route.model,
      max_tokens: 256,
      system: "Decide whether a note is a GENERIC, reusable procedure (a process, checklist or website flow anyone could follow) or something specific to one person's life or business. Placeholders like [name], [amount], [date] are fine. Answer generic=true only for reusable procedures.",
      messages: [{ role: "user", content: text.slice(0, 4000) }],
      output_config: { format: { type: "json_schema", schema: CLASSIFY_SCHEMA } },
    });
    const block = res.content.find((b) => b.type === "text");
    const parsed = JSON.parse(block && block.type === "text" ? block.text : "{}") as { generic?: boolean; reason?: string };
    return { generic: !!parsed.generic, certain: true, reasons: [...h.reasons, `model (${route.model}): ${parsed.reason ?? ""}`] };
  } catch (e) {
    console.warn("[brain] classifier model failed, keeping heuristics:", e instanceof Error ? e.message : e);
    return h;
  }
}

// MARK: - Candidates

export function titleFor(text: string, max = 80): string {
  const line = text.trim().split("\n")[0].replace(/^\s*(?:\d+[.)]|[-*•#]+)\s*/, "").trim();
  const first = line.split(/(?<=[.!?])\s/)[0];
  const t = first.length > max ? first.slice(0, max - 1).replace(/\s+\S*$/, "") + "…" : first;
  return t.replace(/^./, (c) => c.toUpperCase()) || "Untitled";
}

/** Build the row that would be stored. Pure and ALWAYS scrubbed — this is
 *  the only way a Candidate object is made, so nothing raw can get through. */
export function prepareCandidate(text: string, kind: CandidateKind, classification: Classification): Candidate {
  const s = scrub(text);
  if (RAW_PII.test(s.text)) throw new Error("scrubber left an address or phone in a candidate");
  return {
    kind,
    title: titleFor(s.text),
    body: capCloudText(s.text),
    scrubbed: s.replacements,
    reasons: classification.reasons,
  };
}

export function asKind(v: unknown): CandidateKind {
  return (CANDIDATE_KINDS as readonly string[]).includes(String(v)) ? (v as CandidateKind) : "other";
}

const norm = (e: string) => e.trim().toLowerCase();

/**
 * Submit a learning from the Mac. Scrub → classify → store only when generic,
 * as `pending_consent`. The raw text never touches the database: the
 * classifier itself runs on the scrubbed text.
 */
export async function submitCandidate(
  email: string,
  input: { text: string; kind?: unknown; key?: string | null },
): Promise<{ stored: PromotionRow | null; generic: boolean; reasons: string[] }> {
  await ensureBrainSchema();
  const scrubbed = scrub(input.text).text;
  const c = await classifyCandidate(scrubbed, { key: input.key });
  if (!c.generic) return { stored: null, generic: false, reasons: c.reasons };
  const candidate = prepareCandidate(input.text, asKind(input.kind), c);
  const row = assertCloudWritable({ kind: "promotion_candidate", residency: "cloud" as const, id: crypto.randomUUID(), email: norm(email) });
  const db = sql();
  const [out] = await db<PromotionRow[]>`
    INSERT INTO promotion_queue (id, email, candidate, status, residency)
    VALUES (${row.id}, ${row.email}, ${JSON.stringify(candidate)}, 'pending_consent', ${row.residency})
    RETURNING *`;
  return { stored: out, generic: true, reasons: c.reasons };
}

export async function pendingCandidates(email: string): Promise<PromotionRow[]> {
  await ensureBrainSchema();
  return sql()<PromotionRow[]>`
    SELECT * FROM promotion_queue WHERE email = ${norm(email)} AND status = 'pending_consent' ORDER BY created_at DESC LIMIT 50`;
}

/** The one question, asked once. Default no: anything but an explicit yes
 *  rejects, and a rejected candidate is never asked about again. */
export async function consent(email: string, id: string, yes: boolean): Promise<PromotionRow | null> {
  await ensureBrainSchema();
  const rows = await sql()<PromotionRow[]>`
    UPDATE promotion_queue
       SET status = ${yes ? "awaiting_review" : "rejected"}, consent_at = now()
     WHERE email = ${norm(email)} AND id = ${id} AND status = 'pending_consent'
    RETURNING *`;
  return rows[0] ?? null;
}

// MARK: - Review and publish (admin)

export async function awaitingReview(): Promise<PromotionRow[]> {
  await ensureBrainSchema();
  return sql()<PromotionRow[]>`SELECT * FROM promotion_queue WHERE status = 'awaiting_review' ORDER BY created_at ASC LIMIT 100`;
}

/** sha256(email + SESSION_SECRET): stable per user, not reversible without
 *  the secret, and the only attribution a published SOP carries. */
export function sourceUserHash(email: string): string {
  const secret = process.env.SESSION_SECRET;
  if (!secret) throw new Error("SESSION_SECRET is not set");
  return createHash("sha256").update(norm(email) + secret).digest("hex");
}

export async function reviewCandidate(id: string, decision: "approve" | "reject"): Promise<{ row: PromotionRow | null; sop: SopRow | null }> {
  await ensureBrainSchema();
  const db = sql();
  const [row] = await db<PromotionRow[]>`SELECT * FROM promotion_queue WHERE id = ${id} AND status = 'awaiting_review'`;
  if (!row) return { row: null, sop: null };
  if (decision === "reject") {
    const [out] = await db<PromotionRow[]>`UPDATE promotion_queue SET status = 'rejected', reviewed_at = now() WHERE id = ${id} RETURNING *`;
    return { row: out, sop: null };
  }
  const c = typeof row.candidate === "string" ? (JSON.parse(row.candidate) as Candidate) : row.candidate;
  // Belt and braces: publish re-scrubs the stored body.
  const body = scrub(c.body).text;
  if (RAW_PII.test(body)) throw new Error("refusing to publish: candidate still carries an address or phone");
  const sop = assertCloudWritable({
    kind: "sop",
    residency: "cloud" as const,
    id: crypto.randomUUID(),
    title: capCloudText(c.title, 200),
    body: capCloudText(body),
    source_user_hash: sourceUserHash(row.email),
  });
  const [{ v }] = await db<{ v: number }[]>`SELECT COALESCE(MAX(version), 0) + 1 AS v FROM shared_sops WHERE title = ${sop.title}`;
  const [published] = await db<SopRow[]>`
    INSERT INTO shared_sops (id, title, body, version, source_user_hash, residency)
    VALUES (${sop.id}, ${sop.title}, ${sop.body}, ${v}, ${sop.source_user_hash}, ${sop.residency})
    RETURNING *`;
  const [out] = await db<PromotionRow[]>`
    UPDATE promotion_queue SET status = 'published', reviewed_at = now(), sop_id = ${published.id} WHERE id = ${id} RETURNING *`;
  return { row: out, sop: published };
}

// MARK: - Reading the Shared Brain

export async function listSops(): Promise<Omit<SopRow, "body">[]> {
  await ensureBrainSchema();
  return sql()<Omit<SopRow, "body">[]>`
    SELECT DISTINCT ON (title) id, title, version, source_user_hash, published_at, residency
      FROM shared_sops ORDER BY title, version DESC`;
}

export async function getSop(id: string): Promise<SopRow | null> {
  await ensureBrainSchema();
  const rows = await sql()<SopRow[]>`SELECT * FROM shared_sops WHERE id = ${id}`;
  return rows[0] ?? null;
}
