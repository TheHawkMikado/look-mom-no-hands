#!/usr/bin/env node
/**
 * Phase 4 demo (SPEC.md §7, §9): the eval-driven router, offline.
 *
 *  1. GET /api/app/routing → today's winner for task_extract (seed opinion).
 *  2. Two fake candidates go into routing_scores with a claimed 0.99:
 *     `rules` (the real deterministic engine) and `demo-pretender` (a local
 *     model that does not exist). The router believes the claim → winner
 *     changes to the pretender.
 *  3. GET /api/cron/evals runs the fixtures with no model key: local
 *     candidates are measured, anthropic rows skipped with a warning.
 *  4. The measured scores replace the claims (pretender → 0, rules → its
 *     real pass rate) and the winner is back to the best measured/seeded row.
 *  5. eval_runs holds one row per candidate; the demo rows are removed.
 *
 *   NOHANDS_APP_TOKEN=… node scripts/phase4-demo.mjs
 *   (DATABASE_URL from the environment or web/.env.local; CRON_SECRET if set)
 */
import { readFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import postgres from "postgres";

const HERE = dirname(fileURLToPath(import.meta.url));
const envFile = resolve(HERE, "..", ".env.local");
const dotenv = existsSync(envFile)
  ? Object.fromEntries(readFileSync(envFile, "utf8").split("\n").filter((l) => l && !l.startsWith("#") && l.includes("=")).map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }))
  : {};
const API = (process.env.NOHANDS_API || "http://localhost:3000").replace(/\/+$/, "");
const TOKEN = process.env.NOHANDS_APP_TOKEN;
const DATABASE_URL = process.env.DATABASE_URL || dotenv.DATABASE_URL;
const CRON_SECRET = process.env.CRON_SECRET || dotenv.CRON_SECRET || "";
if (!TOKEN) { console.error("NOHANDS_APP_TOKEN required"); process.exit(2); }
if (!DATABASE_URL) { console.error("DATABASE_URL required (env or web/.env.local)"); process.exit(2); }

const sql = postgres(DATABASE_URL, { max: 1 });
async function api(method, path, body, auth = `Bearer ${TOKEN}`) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: auth, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${JSON.stringify(json)}`);
  return json;
}
const step = (n, s) => console.log(`\n[${n}] ${s}`);
const fail = async (s) => { console.error(`\nFAIL: ${s}`); await cleanup(); process.exit(1); };
const TYPE = "task_extract";
const FAKES = ["rules", "demo-pretender"];
const cleanup = () => sql`DELETE FROM routing_scores WHERE task_type = ${TYPE} AND model IN ${sql(FAKES)}`;
const winner = async () => (await api("GET", "/api/app/routing?fresh=1")).routes[TYPE];
const show = (r) => `${r.model} (${r.provider}) — candidates: ${r.candidates.map((c) => `${c.model}@${c.score}`).join(", ")}`;

try {
  await cleanup();
  step(1, `Today's winner for ${TYPE}`);
  const w0 = await winner();
  console.log(`    ${show(w0)}`);
  if (w0.provider === "local") await fail("expected a seeded model winner before the demo");

  step(2, "Two fake candidates claim 0.99: `rules` (real engine) and `demo-pretender` (does not exist)");
  for (const m of FAKES) {
    await sql`INSERT INTO routing_scores (task_type, model, provider, score, cost_per_1k, latency_p50, latency_first, options)
              VALUES (${TYPE}, ${m}, 'local', 0.99, 0, 5, false, '{}')`;
  }
  const w1 = await winner();
  console.log(`    ${show(w1)}`);
  if (!FAKES.includes(w1.model)) await fail("a claimed 0.99 should win until it is measured");
  console.log("    → the router trusts the claim: a seed score is an opinion until the eval job measures it");

  step(3, "Run the evals offline (no model key) via GET /api/cron/evals");
  const run = await api("GET", `/api/cron/evals?types=${TYPE},triage_decision,intent_classify`, undefined, CRON_SECRET ? `Bearer ${CRON_SECRET}` : "");
  console.log(`    key_present=${run.key_present}`);
  for (const c of run.candidates) {
    console.log(`    ${c.task_type.padEnd(16)} ${c.model.padEnd(18)} ${c.status.padEnd(10)} ${c.score != null ? `score=${c.score}${c.cases ? ` (${c.passed}/${c.cases}) p50=${c.latency_p50}ms` : ""}` : ""}${c.warning ? ` — ${c.warning}` : ""}`);
  }
  const rules = run.candidates.find((c) => c.task_type === TYPE && c.model === "rules");
  const pretender = run.candidates.find((c) => c.task_type === TYPE && c.model === "demo-pretender");
  if (rules?.status !== "scored") await fail("the rules engine should be measurable with no key");
  if (pretender?.status !== "unrunnable" || pretender.score !== 0) await fail("a local candidate with no engine must be scored 0");
  const anth = run.candidates.filter((c) => c.provider === "anthropic");
  if (run.key_present === false && anth.some((c) => c.status !== "skipped")) await fail("model rows must be skipped without a key");
  console.log(`    winners: ${Object.entries(run.winners).map(([t, w]) => `${t}: ${w.before} → ${w.after}`).join(" | ")}`);

  step(4, "The winner after measurement");
  const w2 = await winner();
  console.log(`    ${show(w2)}`);
  if (w2.model === "demo-pretender") await fail("the pretender still wins");
  if (w2.model !== w0.model && w2.model !== "rules") await fail(`unexpected winner ${w2.model}`);
  const rulesRow = (await sql`SELECT score, last_evaluated_at FROM routing_scores WHERE task_type = ${TYPE} AND model = 'rules'`)[0];
  console.log(`    rules: claimed 0.99, measured ${rulesRow.score} (last_evaluated_at=${rulesRow.last_evaluated_at.toISOString()})`);
  console.log(`    ${w0.model} → ${w1.model} → ${w2.model}`);

  step(5, "eval_runs is the audit trail; the seed never clobbers a measured score");
  const runs = await sql`SELECT model, status, score, passed, cases FROM eval_runs WHERE task_type = ${TYPE} AND ran_at >= ${run.ran_at} ORDER BY model`;
  for (const r of runs) console.log(`    ${r.model.padEnd(18)} ${r.status.padEnd(10)} ${r.score ?? "—"} ${r.cases ? `(${r.passed}/${r.cases})` : ""}`);
  // The seed upsert (router.ts ensureRoutingSchema) keeps a measured score.
  await sql`INSERT INTO routing_scores (task_type, model, provider, score, cost_per_1k, latency_p50, latency_first, options)
            VALUES (${TYPE}, 'rules', 'local', 0.99, 0, 5, false, '{}')
            ON CONFLICT (task_type, model) DO UPDATE SET
              score = CASE WHEN routing_scores.last_evaluated_at IS NULL THEN EXCLUDED.score ELSE routing_scores.score END`;
  const after = (await sql`SELECT score FROM routing_scores WHERE task_type = ${TYPE} AND model = 'rules'`)[0];
  if (Number(after.score) !== Number(rulesRow.score)) await fail("the seed clobbered a measured score");
  console.log(`    re-seeding rules@0.99 left the measured ${after.score} in place`);

  await cleanup();
  console.log("\n    demo rows removed; the table is back to the seed + measurements of real candidates");
  console.log("\nPhase 4 demo passed.");
} finally {
  await sql.end();
}
