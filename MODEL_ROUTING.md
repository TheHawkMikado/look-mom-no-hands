# Model routing table

The living routing table (SPEC.md §7). `web/lib/router.ts` seeds the
`routing_scores` table from `web/lib/routing-seed.ts`, which mirrors this
file; clients fetch the resolved table from `GET /api/app/routing`. Never
hardcode a model inside a feature. Change a model here AND in the seed file.

Phase 0 seeds are opinionated defaults. Phase 4 replaces `score` with measured
eval results and adds `cost_per_1k`, `latency_p50` from real runs.

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
| call_agent_realtime  | (none)            | —     | Phase 3; provider TBD (Vapi/Retell vs Twilio + realtime model) |
| stt                  | apple-speech      | 0.80  | on-device; latency-first; Phase 2 evaluates streaming cloud STT with diarization |
| diarization          | (none)            | —     | Phase 2 |
| speaker_id           | ecapa-tdnn-coreml | 0.80  | on-device; see PLAN-SPEAKER-VERIFICATION.md |

## Where the Mac app is today

`Sources/LookMomNoHands/ClaudeClient.swift` hardcodes `claude-haiku-4-5` for
command routing and `claude-opus-4-8` for dictation reports. Phase 1 moves
both behind the router (fetch + cache, fall back to the built-in seed when
offline).

## Provider notes

- Anthropic is the only provider wired today. Adding a provider means a new
  `provider` value in the seed and an adapter in `web/lib/llm/`; the router
  and evals do not change.
- Fable-class models reject forced tool use and always think; the extraction
  path uses structured outputs, not forced tools, so it is portable across
  the family.
