import Anthropic from "@anthropic-ai/sdk";
import { sql } from "@/lib/db";
import { ensureBrainSchema } from "@/lib/db-brain";
import { extractWithModel, fallbackExtract, finalizeExtraction, type Extraction } from "@/lib/extract";
import { invalidateRoutingCache, resolve, type RoutingRow } from "@/lib/router";
import type { TaskType } from "@/lib/routing-seed";
import { triage } from "@/lib/triage";
import type { PaperclipAgentRef } from "@/lib/db-tasks";
import intentClassify from "./fixtures/intent_classify.json";
import taskExtract from "./fixtures/task_extract.json";
import triageDecision from "./fixtures/triage_decision.json";
import summarizeMeeting from "./fixtures/summarize_meeting.json";
import draftCopyShort from "./fixtures/draft_copy_short.json";

/**
 * Eval-driven router (SPEC.md §7, Phase 4). For every (task_type, candidate)
 * row in `routing_scores` that has a fixture set, run the fixtures against
 * that candidate and write the measured score, blended cost per 1k tokens and
 * p50 latency back — plus one `eval_runs` row per candidate as the audit
 * trail. The seed never clobbers a measured score (router.ts), so from the
 * first run on the table is evidence, not opinion.
 *
 * Two fixture kinds:
 *  - deterministic (intent_classify, task_extract, triage_decision): expected
 *    fields compared exactly; a case passes only when every expected field
 *    matches. Provider `local` is the rules engine (lib/extract.ts,
 *    lib/triage.ts) and needs no key, so it is measurable anywhere.
 *  - rubric (summarize_meeting, draft_copy_short): the candidate answers the
 *    prompt and the `eval_judge` route scores it 0–1 against the rubric.
 *    Needs a key; skipped with a warning otherwise.
 *
 * A candidate that cannot be run is never silently kept: anthropic without a
 * key is `skipped` (score untouched — unmeasured, not wrong); a `local` model
 * with no engine in this repo is `unrunnable` and scored 0, because nothing
 * can route to code that does not exist.
 */

export interface DeterministicCase {
  id: string;
  text: string;
  expected: Record<string, unknown>;
  has_paperclip?: boolean;
}
export interface RubricCase {
  id: string;
  prompt: string;
  rubric: string;
}
export interface FixtureSet {
  task_type: TaskType;
  kind: "deterministic" | "rubric";
  agents?: PaperclipAgentRef[];
  cases: (DeterministicCase | RubricCase)[];
}

export const FIXTURES: Record<string, FixtureSet> = {
  intent_classify: intentClassify as FixtureSet,
  task_extract: taskExtract as FixtureSet,
  triage_decision: triageDecision as FixtureSet,
  summarize_meeting: summarizeMeeting as FixtureSet,
  draft_copy_short: draftCopyShort as FixtureSet,
};

/** USD per million tokens (MODEL_ROUTING.md price table). Used to turn a
 *  run's token usage into a blended cost per 1k tokens. Unknown models get
 *  the seed's cost_per_1k left as is. */
export const PRICES_PER_M: Record<string, { input: number; output: number }> = {
  "claude-opus-5": { input: 5, output: 25 },
  "claude-sonnet-4-5": { input: 3, output: 15 },
  "claude-haiku-4-5": { input: 1, output: 5 },
};

/** Local engines: the deterministic code paths a `local` candidate can name. */
export const LOCAL_ENGINES: Record<string, (text: string) => Extraction> = {
  rules: (text) => fallbackExtract(text, "rules"),
};

export type EvalStatus = "scored" | "skipped" | "unrunnable" | "failed";

export interface CaseResult {
  id: string;
  pass: boolean | null;
  /** 0–1 for rubric cases; 1/0 for deterministic. */
  score: number;
  got: Record<string, unknown> | string | null;
  expected?: Record<string, unknown>;
  ms: number;
  note?: string;
}

export interface CandidateResult {
  task_type: TaskType;
  model: string;
  provider: string;
  status: EvalStatus;
  score: number | null;
  cases: number;
  passed: number;
  cost_per_1k: number | null;
  latency_p50: number | null;
  results: CaseResult[];
  warning?: string;
}

/** The fields of an extraction a deterministic fixture may assert on. */
function project(x: Extraction, expected: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(expected)) out[k] = (x as unknown as Record<string, unknown>)[k] ?? null;
  return out;
}

function same(a: unknown, b: unknown): boolean {
  if (typeof a === "string" && typeof b === "string") return a.trim().toLowerCase() === b.trim().toLowerCase();
  return a === b || (a == null && b == null);
}

/** Exact scoring: a case passes when every expected field matches. Pure. */
export function scoreDeterministic(cases: DeterministicCase[], outputs: { id: string; got: Record<string, unknown>; ms: number }[]): CaseResult[] {
  return cases.map((c) => {
    const o = outputs.find((x) => x.id === c.id);
    if (!o) return { id: c.id, pass: false, score: 0, got: null, expected: c.expected, ms: 0, note: "no output" };
    const pass = Object.keys(c.expected).every((k) => same(o.got[k], c.expected[k]));
    return { id: c.id, pass, score: pass ? 1 : 0, got: o.got, expected: c.expected, ms: o.ms };
  });
}

export function p50(ms: number[]): number {
  if (ms.length === 0) return 0;
  const s = [...ms].sort((a, b) => a - b);
  return Math.round(s[Math.floor((s.length - 1) / 2)]);
}

function summarize(base: Omit<CandidateResult, "status" | "score" | "cases" | "passed" | "latency_p50" | "results">, results: CaseResult[], cost: number | null): CandidateResult {
  const cases = results.length;
  const passed = results.filter((r) => r.pass === true).length;
  const score = cases ? results.reduce((a, r) => a + r.score, 0) / cases : 0;
  return { ...base, status: "scored", score: Math.round(score * 1000) / 1000, cases, passed, cost_per_1k: cost, latency_p50: p50(results.map((r) => r.ms)), results };
}

/** Run one deterministic fixture set through one extraction function. The
 *  triage fixture pipes the extraction through the (deterministic) triage. */
export async function runDeterministic(
  set: FixtureSet,
  extract: (text: string) => Promise<{ x: Extraction; ms: number; usage?: { input_tokens: number; output_tokens: number } }>,
): Promise<{ outputs: { id: string; got: Record<string, unknown>; ms: number }[]; tokens: { input: number; output: number } }> {
  const outputs: { id: string; got: Record<string, unknown>; ms: number }[] = [];
  const tokens = { input: 0, output: 0 };
  for (const c of set.cases as DeterministicCase[]) {
    const { x, ms, usage } = await extract(c.text);
    if (usage) {
      tokens.input += usage.input_tokens;
      tokens.output += usage.output_tokens;
    }
    let got: Record<string, unknown>;
    if (set.task_type === "triage_decision") {
      const t = triage(x, set.agents ?? [], c.has_paperclip ?? true);
      got = project({ ...x, ...t } as unknown as Extraction, c.expected);
    } else {
      got = project(x, c.expected);
    }
    outputs.push({ id: c.id, got, ms });
  }
  return { outputs, tokens };
}

function blendedCostPer1k(model: string, tokens: { input: number; output: number }): number | null {
  const p = PRICES_PER_M[model];
  const total = tokens.input + tokens.output;
  if (!p || total === 0) return null;
  const usd = (tokens.input * p.input + tokens.output * p.output) / 1_000_000;
  return Math.round((usd / (total / 1000)) * 1e6) / 1e6;
}

// MARK: - Anthropic candidates (need a key)

async function anthropicText(key: string, model: string, options: Record<string, unknown>, prompt: string) {
  const client = new Anthropic({ apiKey: key });
  const t0 = Date.now();
  const res = await client.messages.create({
    model,
    max_tokens: 1024,
    messages: [{ role: "user", content: prompt }],
    ...(options.effort ? { output_config: { effort: options.effort as "low" | "medium" | "high" } } : {}),
  });
  const text = res.content.filter((b) => b.type === "text").map((b) => (b.type === "text" ? b.text : "")).join("\n");
  return { text, ms: Date.now() - t0, usage: { input_tokens: res.usage.input_tokens, output_tokens: res.usage.output_tokens } };
}

const JUDGE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["score", "reason"],
  properties: { score: { type: "number", minimum: 0, maximum: 1 }, reason: { type: "string" } },
} as const;

/** The LLM judge: scores one answer 0–1 against a rubric. Model from the
 *  `eval_judge` route — never hardcoded here. */
export async function judge(key: string, judgeModel: string, prompt: string, answer: string, rubric: string): Promise<{ score: number; reason: string }> {
  const client = new Anthropic({ apiKey: key });
  const res = await client.messages.create({
    model: judgeModel,
    max_tokens: 512,
    system: "You grade one answer against a rubric. Return a score from 0 to 1 (1 = every rubric point met, 0 = none) and one sentence of reason. Be strict about hard constraints (word counts, forbidden words, invented details).",
    messages: [{ role: "user", content: `PROMPT:\n${prompt}\n\nANSWER:\n${answer}\n\nRUBRIC:\n${rubric}` }],
    output_config: { format: { type: "json_schema", schema: JUDGE_SCHEMA } },
  });
  const block = res.content.find((b) => b.type === "text");
  const parsed = JSON.parse(block && block.type === "text" ? block.text : "{}") as { score?: number; reason?: string };
  return { score: Math.min(1, Math.max(0, Number(parsed.score ?? 0))), reason: parsed.reason ?? "" };
}

// MARK: - One candidate

export interface EvalContext {
  key: string | null;
  /** Resolved `eval_judge` route, when a key exists. */
  judgeModel: string | null;
  log?: (s: string) => void;
}

export async function evaluateCandidate(row: RoutingRow, ctx: EvalContext): Promise<CandidateResult> {
  const set = FIXTURES[row.task_type];
  const base = { task_type: row.task_type as TaskType, model: row.model, provider: row.provider, cost_per_1k: null as number | null };
  const skip = (status: EvalStatus, warning: string, score: number | null = null): CandidateResult => ({
    ...base, status, score, cases: 0, passed: 0, latency_p50: null, results: [], warning,
  });
  if (!set) return skip("skipped", `no fixtures for ${row.task_type}`);

  if (set.kind === "deterministic") {
    if (row.provider === "local") {
      const engine = LOCAL_ENGINES[row.model];
      if (!engine) return skip("unrunnable", `no local engine named "${row.model}" — scored 0`, 0);
      const { outputs } = await runDeterministic(set, async (text) => {
        const t0 = process.hrtime.bigint();
        const x = engine(text);
        return { x, ms: Number(process.hrtime.bigint() - t0) / 1e6 };
      });
      return summarize({ ...base, cost_per_1k: 0 }, scoreDeterministic(set.cases as DeterministicCase[], outputs), 0);
    }
    if (row.provider !== "anthropic") return skip("skipped", `provider ${row.provider} has no eval adapter`);
    if (!ctx.key) return skip("skipped", "no Anthropic key — model candidates left unmeasured");
    try {
      const { outputs, tokens } = await runDeterministic(set, async (text) => {
        const r = await extractWithModel(ctx.key!, row.model, row.options ?? {}, text);
        return { x: finalizeExtraction(text, r.parsed, row.model), ms: r.ms, usage: r.usage };
      });
      return summarize(base, scoreDeterministic(set.cases as DeterministicCase[], outputs), blendedCostPer1k(row.model, tokens));
    } catch (e) {
      return { ...skip("failed", e instanceof Error ? e.message : String(e)) };
    }
  }

  // Rubric sets: candidate answers, judge scores.
  if (row.provider !== "anthropic") return skip("skipped", `provider ${row.provider} has no eval adapter`);
  if (!ctx.key || !ctx.judgeModel) return skip("skipped", "no Anthropic key — rubric cases need a candidate and a judge");
  try {
    const results: CaseResult[] = [];
    const tokens = { input: 0, output: 0 };
    for (const c of set.cases as RubricCase[]) {
      const a = await anthropicText(ctx.key, row.model, row.options ?? {}, c.prompt);
      tokens.input += a.usage.input_tokens;
      tokens.output += a.usage.output_tokens;
      const j = await judge(ctx.key, ctx.judgeModel, c.prompt, a.text, c.rubric);
      results.push({ id: c.id, pass: j.score >= 0.7, score: j.score, got: a.text.slice(0, 1000), ms: a.ms, note: j.reason });
    }
    return summarize(base, results, blendedCostPer1k(row.model, tokens));
  } catch (e) {
    return skip("failed", e instanceof Error ? e.message : String(e));
  }
}

// MARK: - The job

export interface EvalRunSummary {
  ran_at: string;
  key_present: boolean;
  candidates: CandidateResult[];
  /** Winner per task type before and after, for the log and the demo. */
  winners: Record<string, { before: string | null; after: string | null }>;
}

export async function runEvals(opts: { key?: string | null; taskTypes?: string[]; log?: (s: string) => void } = {}): Promise<EvalRunSummary> {
  const db = sql();
  await ensureBrainSchema(db);
  const log = opts.log ?? ((s: string) => console.log(`[evals] ${s}`));
  const key = opts.key === undefined ? (process.env.ANTHROPIC_API_KEY ?? null) : opts.key;
  const rows = await db<RoutingRow[]>`SELECT * FROM routing_scores`;
  const judgeRoute = resolve("eval_judge", rows.filter((r) => r.task_type === "eval_judge"));
  const ctx: EvalContext = { key, judgeModel: judgeRoute?.provider === "anthropic" ? judgeRoute.model : null, log };
  if (!key) log("no Anthropic key: only `local` candidates are measured; model rows are skipped with a warning");

  const types = new Set((opts.taskTypes && opts.taskTypes.length ? opts.taskTypes : Object.keys(FIXTURES)).filter((t) => FIXTURES[t]));
  const candidates = rows.filter((r) => types.has(r.task_type));
  const before = winnersOf(rows, types);
  const out: CandidateResult[] = [];
  const ranAt = new Date();

  for (const row of candidates) {
    const r = await evaluateCandidate(row, ctx);
    out.push(r);
    log(`${r.task_type} / ${r.model} (${r.provider}): ${r.status}${r.score != null ? ` score=${r.score} (${r.passed}/${r.cases})` : ""}${r.warning ? ` — ${r.warning}` : ""}`);
    await db`
      INSERT INTO eval_runs (id, task_type, model, provider, status, score, cases, passed, cost_per_1k, latency_p50, detail, ran_at)
      VALUES (${crypto.randomUUID()}, ${r.task_type}, ${r.model}, ${r.provider}, ${r.status}, ${r.score}, ${r.cases}, ${r.passed},
              ${r.cost_per_1k}, ${r.latency_p50}, ${JSON.stringify({ warning: r.warning ?? null, results: r.results })}, ${ranAt})`;
    if (r.status === "scored" || r.status === "unrunnable") {
      await db`
        UPDATE routing_scores
           SET score = ${r.score ?? 0},
               cost_per_1k = COALESCE(${r.cost_per_1k}, cost_per_1k),
               latency_p50 = COALESCE(${r.latency_p50}, latency_p50),
               last_evaluated_at = ${ranAt}
         WHERE task_type = ${r.task_type} AND model = ${r.model}`;
    }
  }
  invalidateRoutingCache();
  const after = winnersOf(await db<RoutingRow[]>`SELECT * FROM routing_scores`, types);
  const winners: EvalRunSummary["winners"] = {};
  for (const t of types) {
    winners[t] = { before: before[t] ?? null, after: after[t] ?? null };
    if (before[t] !== after[t]) log(`${t}: winner ${before[t] ?? "—"} → ${after[t] ?? "—"}`);
  }
  return { ran_at: ranAt.toISOString(), key_present: !!key, candidates: out, winners };
}

function winnersOf(rows: RoutingRow[], types: Set<string>): Record<string, string | null> {
  const out: Record<string, string | null> = {};
  for (const t of types) out[t] = resolve(t as TaskType, rows.filter((r) => r.task_type === t))?.model ?? null;
  return out;
}
