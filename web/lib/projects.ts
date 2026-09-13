import { sql } from "@/lib/db";
import { ensureBrainSchema } from "@/lib/db-brain";
import {
  createProject,
  getPaperclipConnection,
  getTask,
  insertReceipt,
  type PaperclipAgentRef,
  type PaperclipConnection,
  type ProjectRow,
  type TaskRow,
} from "@/lib/db-tasks";
import type { Extraction } from "@/lib/extract";
import { gateNotify } from "@/lib/gate";
import { PaperclipClient } from "@/lib/paperclip";
import { assertCloudWritable, capCloudText, type Residency } from "@/lib/residency";
import type { Tier } from "@/lib/tiers";
import { matchAgent } from "@/lib/triage";

/**
 * Phase 5 (SPEC.md §9): the first real business workflow — the multi-model
 * ad-creation process as a No Hands project with a budget cap and a review
 * gate before anything is published or paid for.
 *
 * Intake with capability `ad_process` creates a project linked to the task
 * and, when Paperclip is connected in direct mode, one issue per step under
 * the task's issue (or as siblings when the task has no issue yet). Spend is
 * recorded against the cap with a receipt; crossing 80% asks the owner once
 * ("keep going?") through the same goal_progress event the phone renders;
 * a spend that would cross the cap is refused.
 */

export interface AdStep {
  step_no: number;
  key: "research" | "angles" | "variants" | "images" | "compliance" | "review" | "publish";
  title: string;
  detail: string;
  /** Blast-radius tier of the step's action in the world (§6). */
  blast_tier: Tier;
  /** Which kind of agent takes it; null = the owner (a gate, not work). */
  role: "research" | "content" | null;
}

/** The ad process, in order. Pure: the demo and the tests read it too. */
export function adProcessPlan(offer: string, budgetCapCents: number | null): AdStep[] {
  const paid = (budgetCapCents ?? 0) > 0;
  return [
    { step_no: 1, key: "research", title: `Research the offer: ${offer}`, detail: "Who it is for, what it promises, proof we can use, and the three objections we will hear. One page.", blast_tier: 0, role: "research" },
    { step_no: 2, key: "angles", title: "Three angles", detail: "Three distinct angles (pain, aspiration, proof) with one sentence each on why it would work for this audience.", blast_tier: 0, role: "content" },
    { step_no: 3, key: "variants", title: "Five copy variants per angle", detail: "Fifteen short ad copies: headline + primary text + CTA, five per angle. No claims we cannot prove.", blast_tier: 0, role: "content" },
    { step_no: 4, key: "images", title: "Image prompts", detail: "One image prompt per angle, plus an alt text line. Describe, do not generate.", blast_tier: 0, role: "content" },
    { step_no: 5, key: "compliance", title: "Compliance and brand check", detail: "Check every variant against platform ad policy (no guaranteed-income or before/after claims) and the brand voice. List what to cut.", blast_tier: 0, role: "research" },
    { step_no: 6, key: "review", title: "Review gate: owner approves the set", detail: "Nothing below this line runs until the owner approves the set on the phone or by voice.", blast_tier: 2, role: null },
    {
      step_no: 7,
      key: "publish",
      title: paid ? "Publish and fund the ads (within the cap)" : "Stage the ads for publishing",
      detail: paid
        ? `Publish the approved set and fund it, never above the ${dollars(budgetCapCents ?? 0)} cap. Every charge is recorded as spend on the project.`
        : "Stage the approved set as drafts in the ad account. Do not fund anything — no budget was approved.",
      blast_tier: paid ? 3 : 2,
      role: "content",
    },
  ];
}

export function dollars(cents: number): string {
  const whole = Math.round(cents) / 100;
  return "$" + (Number.isInteger(whole) ? whole.toLocaleString("en-US") : whole.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
}

/** Did this spend take the project across the 80% line? Pure. */
export function crossed80(before: number, after: number, cap: number): boolean {
  if (cap <= 0) return false;
  const line = cap * 0.8;
  return before < line && after >= line;
}

export interface ProjectStepRow {
  id: string;
  project_id: string;
  email: string;
  step_no: number;
  title: string;
  blast_tier: number;
  assignee_agent_id: string | null;
  paperclip_issue_id: string | null;
  paperclip_issue_key: string | null;
  status: string;
  residency: Residency;
  created_at: Date;
}

export type ProjectWithMeta = ProjectRow & { task_id: string | null; paperclip_project_id: string | null; budget_warned_at: Date | null };

const norm = (e: string) => e.trim().toLowerCase();

/** The offer named in "run the ad process for X (with a $Y cap)". */
export function offerFrom(title: string, detail: string): string {
  // The title has the budget clause stripped already (extract.ts titleFrom),
  // so it is tried first; the detail is the raw utterance.
  const re = /\b(?:for|on|about)\s+(?:the\s+)?(.+?)(?:\s*[,.;]|\s+(?:with|under|at)\s+(?:a|an)?\s*\$.*|$)/i;
  const m = re.exec(title) ?? re.exec(detail);
  const offer = (m?.[1] ?? title).replace(/\s+(?:offer|campaign)$/i, "").trim();
  return offer.length > 80 ? offer.slice(0, 79) + "…" : offer || title;
}

// MARK: - Intake hook

/**
 * Called from intake when the extraction's capability is `ad_process`:
 *   if (x.capability === "ad_process") await onAdProcessIntake(task, x);
 * Idempotent per task.
 */
export async function onAdProcessIntake(
  task: TaskRow,
  x: Pick<Extraction, "title" | "detail" | "budget_cap_cents">,
): Promise<{ project: ProjectWithMeta; steps: ProjectStepRow[]; paperclip: { issues: number; project_id: string | null; error: string | null } }> {
  await ensureBrainSchema();
  const db = sql();
  const email = norm(task.email);
  const existing = await db<ProjectWithMeta[]>`SELECT * FROM projects WHERE email = ${email} AND task_id = ${task.id}`;
  if (existing[0]) {
    return { project: existing[0], steps: await stepsOf(existing[0].id), paperclip: { issues: 0, project_id: existing[0].paperclip_project_id, error: null } };
  }

  const offer = offerFrom(x.title, x.detail);
  const cap = x.budget_cap_cents ?? 0;
  const created = await createProject(email, `Ad process: ${offer}`, cap);
  await db`UPDATE projects SET task_id = ${task.id} WHERE id = ${created.id}`;
  await db`UPDATE tasks SET project_id = ${created.id}, updated_at = now() WHERE id = ${task.id} AND email = ${email}`;

  const plan = adProcessPlan(offer, x.budget_cap_cents);
  const steps: ProjectStepRow[] = [];
  for (const s of plan) {
    const row = assertCloudWritable({
      kind: "project_step",
      residency: "cloud" as const,
      id: crypto.randomUUID(),
      project_id: created.id,
      email,
      step_no: s.step_no,
      title: capCloudText(s.title, 200),
      blast_tier: s.blast_tier,
    });
    const [out] = await db<ProjectStepRow[]>`
      INSERT INTO project_steps (id, project_id, email, step_no, title, blast_tier, residency)
      VALUES (${row.id}, ${row.project_id}, ${row.email}, ${row.step_no}, ${row.title}, ${row.blast_tier}, ${row.residency})
      RETURNING *`;
    steps.push(out);
  }
  await insertReceipt(email, {
    task_id: task.id,
    actor: "system",
    summary: `Ad process project created (${plan.length} steps, cap ${cap > 0 ? dollars(cap) : "none"}; review gate before publish${cap > 0 ? ", tier 3 to fund" : ""}).`,
    ref: created.id,
  });

  // Paperclip, direct mode only: one issue per step. Bridge mode gets these
  // on a later phase; the project and steps exist either way.
  const conn = await getPaperclipConnection(email);
  const pcOut = { issues: 0, project_id: null as string | null, error: null as string | null };
  if (conn && conn.mode === "direct") {
    try {
      const fresh = (await getTask(email, task.id)) ?? task;
      const r = await createStepIssues(conn, fresh, created, plan, steps);
      pcOut.issues = r.issues;
      pcOut.project_id = r.projectId;
      if (r.projectId) await db`UPDATE projects SET paperclip_project_id = ${r.projectId} WHERE id = ${created.id}`;
      await insertReceipt(email, {
        task_id: task.id,
        actor: "system",
        summary: `${r.issues} step issues created in Paperclip${fresh.paperclip_issue_key ? ` under ${fresh.paperclip_issue_key}` : " (no parent issue yet — siblings)"}${r.projectId ? " in the Ad process project" : ""}.`,
      });
    } catch (e) {
      pcOut.error = e instanceof Error ? e.message : String(e);
      await insertReceipt(email, { task_id: task.id, actor: "system", summary: `Paperclip step issues failed: ${pcOut.error}` });
    }
  }
  const [project] = await db<ProjectWithMeta[]>`SELECT * FROM projects WHERE id = ${created.id}`;
  return { project, steps: await stepsOf(created.id), paperclip: pcOut };
}

function agentFor(role: AdStep["role"], agents: PaperclipAgentRef[]): PaperclipAgentRef | null {
  if (!role) return null;
  return matchAgent(role === "research" ? "research" : "draft_copy", null, agents);
}

async function createStepIssues(
  conn: PaperclipConnection & { apiKey: string | null },
  task: TaskRow,
  project: ProjectRow,
  plan: AdStep[],
  steps: ProjectStepRow[],
): Promise<{ issues: number; projectId: string | null }> {
  const pc = new PaperclipClient({ url: conn.url, apiKey: conn.apiKey });
  const db = sql();
  // The "Ad process" template project from `bootstrap.mjs --ads`, if present.
  const projectId = (await pc.listProjects(conn.company_id).catch(() => []))
    .find((p) => /^ad process\b/i.test(p.name))?.id ?? null;
  let n = 0;
  for (const s of plan) {
    const agent = agentFor(s.role, conn.agents);
    const issue = await pc.createIssue(conn.company_id, {
      title: `${s.step_no}. ${s.title}`,
      description: [
        s.detail,
        "",
        "---",
        `No Hands project ${project.id} (task ${task.id}), step ${s.step_no} of ${plan.length}. Blast-radius tier ${s.blast_tier}.`,
        project.budget_cap_cents > 0 ? `Budget cap ${dollars(project.budget_cap_cents)}; every charge is recorded via POST /api/app/projects/${project.id}/spend.` : "No budget approved: nothing may be funded.",
        s.blast_tier >= 2 ? "Do NOT publish, send, or spend anything yourself — the owner approves that step." : "When your work is ready, post it as a comment and set the issue to in_review.",
      ].join("\n"),
      status: s.step_no === 1 ? "todo" : "backlog",
      priority: "medium",
      ...(agent ? { assigneeAgentId: agent.id } : {}),
      ...(task.paperclip_issue_id ? { parentId: task.paperclip_issue_id } : {}),
      ...(projectId ? { projectId } : {}),
    });
    const step = steps.find((r) => r.step_no === s.step_no);
    if (step) {
      await db`
        UPDATE project_steps
           SET paperclip_issue_id = ${issue.id}, paperclip_issue_key = ${issue.identifier}, assignee_agent_id = ${agent?.id ?? null}, status = 'issued'
         WHERE id = ${step.id}`;
    }
    n++;
  }
  return { issues: n, projectId };
}

export async function stepsOf(projectId: string): Promise<ProjectStepRow[]> {
  return sql()<ProjectStepRow[]>`SELECT * FROM project_steps WHERE project_id = ${projectId} ORDER BY step_no`;
}

export async function getProject(email: string, id: string): Promise<ProjectWithMeta | null> {
  await ensureBrainSchema();
  const rows = await sql()<ProjectWithMeta[]>`SELECT * FROM projects WHERE email = ${norm(email)} AND id = ${id}`;
  return rows[0] ?? null;
}

// MARK: - Spend

export interface SpendResult {
  ok: boolean;
  reason?: string;
  project: ProjectWithMeta;
  /** True when this spend crossed 80% of the cap and the owner was asked. */
  warned: boolean;
  capped: boolean;
}

/** Record spend against the cap. Refuses to cross the cap; asks the owner
 *  once at 80%; marks the project `capped` when the cap is reached. */
export async function recordSpend(email: string, projectId: string, cents: number, note: string): Promise<SpendResult | null> {
  const project = await getProject(email, projectId);
  if (!project) return null;
  const amount = Math.round(Number(cents));
  if (!Number.isFinite(amount) || amount <= 0) return { ok: false, reason: "cents must be a positive integer", project, warned: false, capped: false };
  const cap = project.budget_cap_cents;
  const before = project.budget_spent_cents;
  const after = before + amount;
  if (cap > 0 && after > cap) {
    return { ok: false, reason: `would exceed the ${dollars(cap)} cap (${dollars(before)} spent, ${dollars(amount)} requested)`, project, warned: false, capped: before >= cap };
  }
  const db = sql();
  const capped = cap > 0 && after >= cap;
  const [updated] = await db<ProjectWithMeta[]>`
    UPDATE projects
       SET budget_spent_cents = ${after}, status = ${capped ? "capped" : project.status}
     WHERE id = ${project.id} AND email = ${norm(email)}
    RETURNING *`;
  if (project.task_id) {
    await insertReceipt(email, {
      task_id: project.task_id,
      actor: "system",
      cost_cents: amount,
      summary: `Spend ${dollars(amount)}: ${capCloudText(note || "(no note)", 300)} — ${dollars(after)} of ${cap > 0 ? dollars(cap) : "no cap"}.`,
      ref: project.id,
    });
  }
  let warned = false;
  if (crossed80(before, after, cap) && !project.budget_warned_at) {
    await gateNotify(
      email,
      `${project.id}:budget80`,
      "goal_progress",
      project.title,
      `Ad process is at 80% of its ${dollars(cap)} cap — keep going?`,
      null,
    );
    await db`UPDATE projects SET budget_warned_at = now() WHERE id = ${project.id}`;
    warned = true;
  }
  if (capped) {
    await gateNotify(email, `${project.id}:capped`, "goal_progress", project.title, `Ad process reached its ${dollars(cap)} cap — nothing more will be funded.`, null);
  }
  return { ok: true, project: updated, warned, capped };
}
