import { sql } from "@/lib/db";
import { QUALITY_FLOOR, ROUTING_SEED, type RoutingSeed, type TaskType } from "@/lib/routing-seed";

/**
 * The model router (SPEC.md §7). One table, one selection rule, served to
 * every client. Features ask `pick("task_extract")` and never name a model.
 */

export interface RoutingRow extends RoutingSeed {
  last_evaluated_at: Date | null;
}

export interface Route {
  task_type: TaskType;
  model: string;
  provider: string;
  options: Record<string, unknown>;
  /** The full ranked list, best first — clients fall back down it. */
  candidates: { model: string; provider: string; score: number }[];
}

export async function ensureRoutingSchema(db = sql()) {
  await db`
    CREATE TABLE IF NOT EXISTS routing_scores (
      task_type         text NOT NULL,
      model             text NOT NULL,
      provider          text NOT NULL,
      score             double precision NOT NULL,
      cost_per_1k       double precision NOT NULL DEFAULT 0,
      latency_p50       integer NOT NULL DEFAULT 0,
      latency_first     boolean NOT NULL DEFAULT false,
      options           jsonb NOT NULL DEFAULT '{}',
      last_evaluated_at timestamptz,
      PRIMARY KEY (task_type, model)
    )`;
  // Seed rows are inserted once; an eval job that later rewrites `score` and
  // `last_evaluated_at` must not be clobbered by the seed on the next boot.
  // A changed seed *does* update cost/latency/options (operator-owned fields).
  for (const r of ROUTING_SEED) {
    await db`
      INSERT INTO routing_scores (task_type, model, provider, score, cost_per_1k, latency_p50, latency_first, options)
      VALUES (${r.task_type}, ${r.model}, ${r.provider}, ${r.score}, ${r.cost_per_1k}, ${r.latency_p50},
              ${r.latency_first}, ${JSON.stringify(r.options ?? {})})
      ON CONFLICT (task_type, model) DO UPDATE SET
        provider = EXCLUDED.provider, cost_per_1k = EXCLUDED.cost_per_1k,
        latency_p50 = EXCLUDED.latency_p50, latency_first = EXCLUDED.latency_first,
        options = EXCLUDED.options,
        score = CASE WHEN routing_scores.last_evaluated_at IS NULL THEN EXCLUDED.score ELSE routing_scores.score END`;
  }
}

/** Selection rule: highest score above the floor, tie-break cost then latency.
 *  Latency-first types: latency, then score above floor, then cost. Pure, so
 *  it is unit-testable and the client can run the same rule on a cached table. */
export function rank(rows: RoutingSeed[]): RoutingSeed[] {
  const eligible = rows.filter((r) => r.score >= QUALITY_FLOOR);
  const pool = eligible.length > 0 ? eligible : rows; // never return nothing
  const latencyFirst = pool.some((r) => r.latency_first);
  return [...pool].sort((a, b) => {
    if (latencyFirst) {
      return a.latency_p50 - b.latency_p50 || b.score - a.score || a.cost_per_1k - b.cost_per_1k;
    }
    return b.score - a.score || a.cost_per_1k - b.cost_per_1k || a.latency_p50 - b.latency_p50;
  });
}

let cache: { at: number; rows: RoutingRow[] } | null = null;
const CACHE_MS = 60_000;

export async function routingTable(): Promise<RoutingRow[]> {
  if (cache && Date.now() - cache.at < CACHE_MS) return cache.rows;
  const db = sql();
  const rows = await db<RoutingRow[]>`SELECT * FROM routing_scores`;
  cache = { at: Date.now(), rows };
  return rows;
}

export function invalidateRoutingCache() {
  cache = null;
}

export async function pick(taskType: TaskType): Promise<Route | null> {
  const rows = (await routingTable()).filter((r) => r.task_type === taskType);
  return resolve(taskType, rows);
}

export function resolve(taskType: TaskType, rows: RoutingSeed[]): Route | null {
  const ranked = rank(rows);
  if (ranked.length === 0) return null;
  const best = ranked[0];
  return {
    task_type: taskType,
    model: best.model,
    provider: best.provider,
    options: best.options ?? {},
    candidates: ranked.map((r) => ({ model: r.model, provider: r.provider, score: r.score })),
  };
}

/** The whole table resolved per task type — what clients fetch and cache. */
export async function resolvedRouting(): Promise<Record<string, Route>> {
  const rows = await routingTable();
  const out: Record<string, Route> = {};
  for (const t of new Set(rows.map((r) => r.task_type))) {
    const route = resolve(t, rows.filter((r) => r.task_type === t));
    if (route) out[t] = route;
  }
  return out;
}
