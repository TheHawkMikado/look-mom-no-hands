/**
 * Seed for the `routing_scores` table. Mirrors MODEL_ROUTING.md — change both.
 * Phase 4 replaces these opinionated scores with measured eval results.
 */

export type TaskType =
  | "stt"
  | "diarization"
  | "speaker_id"
  | "intent_classify"
  | "task_extract"
  | "summarize_meeting"
  | "draft_copy_short"
  | "draft_copy_long"
  | "research_synthesize"
  | "code_change"
  | "image_prompt"
  | "call_agent_realtime"
  | "triage_decision"
  | "eval_judge"
  | "promotion_classify";

export interface RoutingSeed {
  task_type: TaskType;
  model: string;
  provider: "anthropic" | "apple" | "local";
  score: number;
  /** USD per 1k *output* tokens, rough, for tie-breaks only. */
  cost_per_1k: number;
  /** Rough p50 latency in ms for a typical call; tie-breaks only. */
  latency_p50: number;
  /** Latency-first task types invert the tie-break order. */
  latency_first: boolean;
  /** Provider-specific knobs the client should pass (effort etc). */
  options?: Record<string, unknown>;
}

/** Providers the eval runner knows how to drive. `local` is the deterministic
 *  rules engine (lib/extract.ts fallbacks, lib/triage.ts) — a real candidate
 *  for the hot-path types, and the one that can be measured with no key. */
export type Provider = RoutingSeed["provider"];

export const QUALITY_FLOOR = 0.6;

export const ROUTING_SEED: readonly RoutingSeed[] = [
  { task_type: "intent_classify", model: "claude-haiku-4-5", provider: "anthropic", score: 0.8, cost_per_1k: 0.005, latency_p50: 600, latency_first: true },
  { task_type: "task_extract", model: "claude-opus-5", provider: "anthropic", score: 0.85, cost_per_1k: 0.025, latency_p50: 1800, latency_first: false, options: { effort: "low" } },
  { task_type: "task_extract", model: "claude-haiku-4-5", provider: "anthropic", score: 0.7, cost_per_1k: 0.005, latency_p50: 700, latency_first: false },
  { task_type: "triage_decision", model: "claude-haiku-4-5", provider: "anthropic", score: 0.75, cost_per_1k: 0.005, latency_p50: 600, latency_first: true },
  { task_type: "summarize_meeting", model: "claude-opus-5", provider: "anthropic", score: 0.9, cost_per_1k: 0.025, latency_p50: 8000, latency_first: false, options: { thinking: "adaptive" } },
  { task_type: "draft_copy_short", model: "claude-opus-5", provider: "anthropic", score: 0.85, cost_per_1k: 0.025, latency_p50: 3000, latency_first: false },
  { task_type: "draft_copy_long", model: "claude-opus-5", provider: "anthropic", score: 0.9, cost_per_1k: 0.025, latency_p50: 12000, latency_first: false, options: { thinking: "adaptive", stream: true } },
  { task_type: "research_synthesize", model: "claude-opus-5", provider: "anthropic", score: 0.9, cost_per_1k: 0.025, latency_p50: 15000, latency_first: false, options: { web_search: true } },
  { task_type: "code_change", model: "claude-opus-5", provider: "anthropic", score: 0.85, cost_per_1k: 0.025, latency_p50: 20000, latency_first: false, options: { effort: "xhigh" } },
  { task_type: "image_prompt", model: "claude-opus-5", provider: "anthropic", score: 0.75, cost_per_1k: 0.025, latency_p50: 2000, latency_first: false },
  // Phase 4: the LLM judge for rubric eval cases and the Shared Brain
  // promotion classifier. Both are generic — no user data reaches them
  // unscrubbed (lib/brain.ts scrubs before the classifier sees anything).
  { task_type: "eval_judge", model: "claude-opus-5", provider: "anthropic", score: 0.9, cost_per_1k: 0.025, latency_p50: 4000, latency_first: false, options: { effort: "medium" } },
  { task_type: "promotion_classify", model: "claude-haiku-4-5", provider: "anthropic", score: 0.75, cost_per_1k: 0.005, latency_p50: 700, latency_first: true },
  { task_type: "stt", model: "apple-speech", provider: "apple", score: 0.8, cost_per_1k: 0, latency_p50: 300, latency_first: true },
  { task_type: "speaker_id", model: "ecapa-tdnn-coreml", provider: "local", score: 0.8, cost_per_1k: 0, latency_p50: 50, latency_first: true },
];
