# Model routing table

The living routing table (SPEC.md §7). `web/lib/router.ts` seeds the
`routing_scores` table from `web/lib/routing-seed.ts`, which mirrors this
file; clients fetch the resolved table from `GET /api/app/routing`. Never
hardcode a model inside a feature. Change a model here AND in the seed file.

Phase 0 seeds are opinionated defaults. Phase 4 (`web/lib/evals/run.ts`)
replaces `score` with measured eval results and writes `cost_per_1k`,
`latency_p50` and `last_evaluated_at` from real runs. A seed can never
overwrite a measured score (router.ts); change a model's *cost or latency*
here and it flows through, change its *score* and it only applies to rows
that have never been evaluated.

## Selection rule

Highest `score` above the quality floor (0.60), tie-break on cost, then
latency. Task types marked *latency-first* invert the tie-break: latency, then
score above floor, then cost.

## Table (2026-09-13)

| task_type            | model             | score | notes |
|----------------------|-------------------|-------|-------|
| intent_classify      | claude-haiku-4-5  | 0.80  | latency-first; question / task / decision / note / smalltalk |
| task_extract         | claude-opus-5     | 0.85  | effort `low`; structured output; hot path, ~1–2 s |
| task_extract         | claude-haiku-4-5  | 0.70  | fallback when opus is slow or unavailable |
| triage_decision      | claude-haiku-4-5  | 0.75  | latency-first; deterministic rules run first, model only breaks ties |
| summarize_meeting    | claude-opus-5     | 0.90  | adaptive thinking |
| draft_copy_short     | claude-opus-5     | 0.85  | |
| draft_copy_long      | claude-opus-5     | 0.90  | adaptive thinking, streamed |
| research_synthesize  | claude-opus-5     | 0.90  | web search tool |
| code_change          | claude-opus-5     | 0.85  | effort `xhigh` |
| image_prompt         | claude-opus-5     | 0.75  | |
| eval_judge           | claude-opus-5     | 0.90  | effort `medium`; the LLM judge for rubric eval cases |
| promotion_classify   | claude-haiku-4-5  | 0.75  | latency-first; Shared Brain classifier, sees scrubbed text only |
| call_agent_realtime  | (none)            | —     | Phase 3; provider TBD (Vapi/Retell vs Twilio + realtime model) |
| stt                  | apple-speech      | 0.80  | on-device; latency-first; Phase 2 evaluates streaming cloud STT with diarization |
| diarization          | (none)            | —     | Phase 2 |
| speaker_id           | ecapa-tdnn-coreml | 0.80  | on-device; see PLAN-SPEAKER-VERIFICATION.md |

## Eval procedure (Phase 4)

Fixtures live in `web/lib/evals/fixtures/<task_type>.json`, one file per
task type, each case with an `id`:

| task_type          | kind          | cases | scored how |
|--------------------|---------------|-------|------------|
| intent_classify    | deterministic | 14    | `expected.intent` exact |
| task_extract       | deterministic | 15    | capability, blast_tier, named_owner, budget_cap_cents — all exact |
| triage_decision    | deterministic | 12    | extraction → `triage()` against the fixture's roster; owner_kind + owner_ref exact |
| summarize_meeting  | rubric        | 5     | candidate answers, `eval_judge` route scores 0–1 |
| draft_copy_short   | rubric        | 5     | same |

Deterministic case = pass only when every expected field matches; score =
passes / cases. Rubric score = mean judge score; a case "passes" at ≥ 0.7.
`latency_p50` is the median wall-clock ms per case; `cost_per_1k` is the
run's blended USD per 1k tokens (input + output, from the price table).

Providers: `local` is the rules engine (`fallbackExtract` in extract.ts,
`triage()` in triage.ts) — model name `rules` — and needs no key, so it is
measured everywhere. `anthropic` rows need a key (`ANTHROPIC_API_KEY`, or
`key` in the admin body) and are otherwise **skipped with a warning and
left unmeasured**. A `local` model with no engine in the repo is
**unrunnable and scored 0**: nothing may route to code that does not exist.

Runs: weekly `GET /api/cron/evals` (Sunday 03:00 UTC, `CRON_SECRET` bearer;
`?types=a,b` narrows), on demand `POST /api/admin/evals/run` (admin session;
body `{ types?, key? }`). Every run writes one `eval_runs` row per
candidate (status, score, passed/cases, per-case detail) and updates
`routing_scores` for scored/unrunnable candidates. `scripts/phase4-demo.mjs`
shows a fake candidate's claimed score being replaced and the winner
changing back, offline.

Rules-engine baseline on 2026-09-13 (no key): intent_classify 0.79 (note,
decision and smalltalk are not recognised), task_extract 0.80 ("ask the
researcher to compare…" mis-parses the owner, "email the client" is not
floored to tier 3, "hire a photographer" is not `purchase`), triage_decision
1.00. Fix the engine, not the fixtures.

## Price table (USD per million tokens)

Used by the eval runner for `cost_per_1k`; `web/lib/evals/run.ts`
(`PRICES_PER_M`) mirrors this table — change both.

| model            | input | output | notes |
|------------------|-------|--------|-------|
| claude-opus-5    | 5.00  | 25.00  | seed cost_per_1k 0.025 = output-only |
| claude-sonnet-4-5| 3.00  | 15.00  | not seeded; listed for candidates |
| claude-haiku-4-5 | 1.00  | 5.00   | seed cost_per_1k 0.005 |
| rules (local)    | 0     | 0      | the deterministic engine |
| apple-speech     | 0     | 0      | on-device |

Verify against the provider's price page when adding a candidate.

## Where the Mac app is today

`ModelRouter.swift` fetches `GET /api/app/routing` at launch and every 6 h,
caches it as `routing.json`, and falls back to a built-in seed identical to
this table when offline. The planner (`intent_classify`) and dictation
reports (`summarize_meeting`) go through it. Remaining hardcoded uses
(agent loop, cleanup, vision, research) move behind the router as those
paths are touched.

## Provider notes

- Anthropic is the only provider wired today. Adding a provider means a new
  `provider` value in the seed and an adapter in `web/lib/llm/`; the router
  and evals do not change.
- Fable-class models reject forced tool use and always think; the extraction
  path uses structured outputs, not forced tools, so it is portable across
  the family.
