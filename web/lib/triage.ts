import type { PaperclipAgentRef } from "@/lib/db-tasks";
import type { Capability, Extraction } from "@/lib/extract";
import { needsApproval } from "@/lib/tiers";

/**
 * Reverse-order delegation (SPEC.md §5.3): agent first, then a human on the
 * team, then — and only as a decision — the user. Deterministic in Phase 0:
 * a role/capability match against the connected Paperclip company. Phase 2
 * adds Person records for the human step; until then it is skipped.
 */

export interface TriageResult {
  owner_kind: "agent" | "human" | "user";
  owner_ref: string | null;
  owner_name: string | null;
  /** The one sentence spoken back to the user. */
  confirmation: string;
  reason: string;
}

/** Which Paperclip roles can take which capability. Role strings are what the
 *  bootstrap creates; a user who renames roles in Paperclip can still match on
 *  the free-text `capabilities` field. */
const ROLE_FOR: Record<Capability, RegExp> = {
  draft_copy: /content|draft|writer|copy|market/i,
  research: /research|analyst/i,
  code: /engineer|developer|code|cto/i,
  email: /content|draft|writer|assistant|ops/i,
  schedule: /assistant|ops|coordinator/i,
  screen_action: /^$/, // Local Runner, not a Paperclip agent
  call: /^$/, // Phase 3
  purchase: /^$/, // never auto-delegated in Phase 0
  other: /assistant|generalist|ops/i,
};

export function matchAgent(cap: Capability, namedOwner: string | null, agents: PaperclipAgentRef[]): PaperclipAgentRef | null {
  if (agents.length === 0) return null;
  const hay = (a: PaperclipAgentRef) => `${a.name} ${a.role} ${a.title ?? ""} ${a.capabilities ?? ""}`;
  if (namedOwner) {
    const n = namedOwner.toLowerCase().replace(/\s+agent$/, "");
    const byName = agents.find((a) => hay(a).toLowerCase().includes(n));
    if (byName) return byName;
  }
  const re = ROLE_FOR[cap];
  return agents.find((a) => re.test(hay(a))) ?? null;
}

export function triage(x: Extraction, agents: PaperclipAgentRef[], hasPaperclip: boolean): TriageResult {
  const agent = hasPaperclip ? matchAgent(x.capability, x.named_owner, agents) : null;
  const when = x.due_phrase ? ` ${x.due_phrase}` : "";
  if (agent) {
    const gate = needsApproval(x.blast_tier)
      ? " and bring it to you before anything goes out"
      : " and let you know when it's done";
    return {
      owner_kind: "agent",
      owner_ref: agent.id,
      owner_name: agent.name,
      confirmation: `I'll have ${agent.name} ${verbFor(x.capability)} that${when}${gate}.`,
      reason: `capability ${x.capability} → ${agent.name} (${agent.role})`,
    };
  }
  // Phase 2: Person records. Phase 0 has no team directory, so a named human
  // becomes a decision for the user rather than a silent drop.
  if (x.named_owner) {
    return {
      owner_kind: "user",
      owner_ref: null,
      owner_name: null,
      confirmation: `I don't have ${x.named_owner} on the team yet. Want me to add them, or handle it another way?`,
      reason: "named owner not found; no team directory in Phase 0",
    };
  }
  return {
    owner_kind: "user",
    owner_ref: null,
    owner_name: null,
    confirmation: hasPaperclip
      ? `Nobody on the team can take "${x.title}" yet. Want me to hire an agent for it, or leave it with you?`
      : `I've noted "${x.title}". Connect a team and I can hand this off next time.`,
    reason: hasPaperclip ? "no agent matched" : "no Paperclip connection",
  };
}

function verbFor(cap: Capability): string {
  switch (cap) {
    case "draft_copy": return "draft";
    case "research": return "look into";
    case "code": return "build";
    case "email": return "write";
    case "schedule": return "schedule";
    default: return "handle";
  }
}
