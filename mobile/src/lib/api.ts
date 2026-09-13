/**
 * Typed client for the nohandsapp.com companion API. The single place that
 * knows the base URL and holds the bearer token; a 401 anywhere flips the app
 * to the signed-out state via the registered handler.
 */

export const SERVER_URL = "https://nohandsapp.com";

export type FeedEventKind =
  | "goal_started"
  | "goal_progress"
  | "needs_approval"
  | "goal_done"
  | "goal_failed";

export type Verdict = "approve" | "deny";

export interface FeedEvent {
  id: string;
  kind: FeedEventKind;
  title: string;
  detail: string;
  approvalId: string | null;
  createdAt: string;
}

export interface FeedResponse {
  /** Newest-first. */
  events: FeedEvent[];
  verdicts: Record<string, Verdict>;
}

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

let bearerToken: string | null = null;
let unauthorizedHandler: (() => void) | null = null;

export function setToken(token: string | null): void {
  bearerToken = token;
}

export function setUnauthorizedHandler(handler: (() => void) | null): void {
  unauthorizedHandler = handler;
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`${SERVER_URL}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(bearerToken ? { Authorization: `Bearer ${bearerToken}` } : {}),
    },
  });
  if (res.status === 401) {
    unauthorizedHandler?.();
    throw new ApiError("Signed out", 401);
  }
  if (!res.ok) {
    throw new ApiError(`${init.method ?? "GET"} ${path} failed`, res.status);
  }
  return (await res.json()) as T;
}

/** Who this token belongs to — shown in Settings so a phone signed into the
 *  wrong account (goals vanish into an inbox no Mac polls) is visible at a
 *  glance instead of failing silently. */
export function getSession(): Promise<{ email: string }> {
  return request("/api/app/session");
}

/** "goal" runs the Mac's agent; "dictation" pastes at the Mac's cursor. */
export type GoalKind = "goal" | "dictation";

export function submitGoal(
  text: string,
  kind: GoalKind = "goal",
): Promise<{ ok: true; id: string }> {
  return request("/api/app/goals", {
    method: "POST",
    body: JSON.stringify({ text, kind }),
  });
}

let feedEtag: string | null = null;

/**
 * The feed, or null when the server says nothing changed (ETag 304) — which is
 * most polls on an idle Mac, and turns ~100KB of repeated JSON into a header
 * exchange twelve times a minute.
 */
export async function getFeed(): Promise<FeedResponse | null> {
  const res = await fetch(`${SERVER_URL}/api/app/feed`, {
    headers: {
      ...(bearerToken ? { Authorization: `Bearer ${bearerToken}` } : {}),
      ...(feedEtag ? { "If-None-Match": feedEtag } : {}),
    },
  });
  if (res.status === 304) return null;
  if (res.status === 401) {
    unauthorizedHandler?.();
    throw new ApiError("Signed out", 401);
  }
  if (!res.ok) throw new ApiError(`GET /api/app/feed failed`, res.status);
  feedEtag = res.headers.get("etag");
  return (await res.json()) as FeedResponse;
}

/**
 * `recorded: false` means someone else decided first (first decision wins
 * server-side) — the caller must NOT show this verdict as the outcome.
 */
export function decideApproval(
  approvalId: string,
  verdict: Verdict,
): Promise<{ ok: true; recorded: boolean }> {
  return request("/api/app/approvals/decide", {
    method: "POST",
    body: JSON.stringify({ approvalId, verdict }),
  });
}

// ---------------------------------------------------------------------------
// Device registration (POST /api/app/device)
// ---------------------------------------------------------------------------

export interface DeviceRegistration {
  /** Stable per-install id — the phone's equivalent of the Mac's device id. */
  device: string;
  version: string;
  /** Expo push token, or null when push is off / permission denied. */
  pushToken: string | null;
  platform: "ios" | "android" | "web" | string;
}

/** Contract: POST /api/app/device { device, version, pushToken, platform }.
 *  The response is the Mac-oriented entitlement payload; the phone only
 *  cares that the call succeeded. */
export function registerDevice(body: DeviceRegistration): Promise<{ ok: true }> {
  return request("/api/app/device", { method: "POST", body: JSON.stringify(body) });
}

// ---------------------------------------------------------------------------
// Tasks (GET/POST /api/app/tasks, GET /api/app/tasks/{id}, /outstanding)
// ---------------------------------------------------------------------------

export type TaskStatus =
  | "triaged"
  | "dispatching"
  | "in_progress"
  | "awaiting_approval"
  | "approved"
  | "denied"
  | "assigned"
  | "needs_decision"
  | "done"
  | "failed";

export type TaskSource = "text" | "voice" | "meeting";
export type OwnerKind = "agent" | "human" | "user";

/** Mirrors web/lib/db-tasks TaskRow; Date columns arrive as ISO strings. */
export interface Task {
  id: string;
  title: string;
  detail: string;
  capability: string;
  owner_kind: OwnerKind;
  owner_ref: string | null;
  owner_name: string | null;
  blast_tier: number;
  status: TaskStatus;
  confirmation: string;
  due_at: string | null;
  paperclip_issue_key: string | null;
  result: string | null;
  closed_at: string | null;
  source: TaskSource;
  created_at: string;
  updated_at: string;
}

export interface TaskApproval {
  id: string;
  task_id: string;
  tier: number;
  question: string;
  requested_at: string;
  decided_at: string | null;
  decision: Verdict | null;
  decided_via: "voice" | "push" | "text" | null;
}

export interface TaskReceipt {
  id: string;
  task_id: string;
  actor: "model" | "agent" | "human" | "user" | "system";
  actor_ref: string | null;
  model_used: string | null;
  cost_cents: number;
  summary: string;
  ref: string | null;
  created_at: string;
}

export interface TaskDetail {
  task: Task;
  approvals: TaskApproval[];
  receipts: TaskReceipt[];
}

export type IntakeIntent = "task" | "question" | "note" | "decision" | string;

/** What POST /api/app/tasks returns: the extracted task (if any) and the
 *  one-sentence confirmation the app reads back. */
export interface IntakeResult {
  intent: IntakeIntent;
  confirmation: string;
  task: Task | null;
}

/** Contract: GET /api/app/tasks?status=a,b&limit=n → { tasks }, newest first. */
export async function getTasks(
  opts: { status?: TaskStatus[]; limit?: number } = {},
): Promise<Task[]> {
  const params = new URLSearchParams();
  if (opts.status?.length) params.set("status", opts.status.join(","));
  if (opts.limit) params.set("limit", String(opts.limit));
  const qs = params.toString();
  const res = await request<{ tasks: Task[] }>(`/api/app/tasks${qs ? `?${qs}` : ""}`);
  return res.tasks ?? [];
}

/** Contract: GET /api/app/tasks/outstanding → { tasks } (everything not
 *  finished). Used for the Tasks tab badge. */
export async function getOutstandingTasks(): Promise<Task[]> {
  const res = await request<{ tasks: Task[] }>("/api/app/tasks/outstanding");
  return res.tasks ?? [];
}

/** Contract: GET /api/app/tasks/{id} → { task, approvals, receipts }. */
export function getTask(id: string): Promise<TaskDetail> {
  return request(`/api/app/tasks/${encodeURIComponent(id)}`);
}

/** Contract: POST /api/app/tasks { text, source } → { intent, confirmation, task }. */
export function createTask(text: string, source: TaskSource): Promise<IntakeResult> {
  return request("/api/app/tasks", {
    method: "POST",
    body: JSON.stringify({ text, source }),
  });
}

// ---------------------------------------------------------------------------
// Prompts — questions the assistant wants to ask the owner
// ---------------------------------------------------------------------------

export interface Prompt {
  id: string;
  question: string;
  /** The answer the assistant will assume; one tap accepts it. */
  default_answer: string;
  /** Free-form discriminator from the server (e.g. "yes_no", "text"). */
  kind: string;
}

/** Contract: GET /api/app/prompts → { prompts: Prompt[] }. A bare array is
 *  tolerated so a stricter server shape doesn't blank the list. */
export async function getPrompts(): Promise<Prompt[]> {
  const res = await request<{ prompts?: Prompt[] } | Prompt[]>("/api/app/prompts");
  if (Array.isArray(res)) return res;
  return res.prompts ?? [];
}

/** Contract: POST /api/app/prompts/{id}/answer { answer } → { ok: true }. */
export function answerPrompt(id: string, answer: string): Promise<{ ok: true }> {
  return request(`/api/app/prompts/${encodeURIComponent(id)}/answer`, {
    method: "POST",
    body: JSON.stringify({ answer }),
  });
}

// ---------------------------------------------------------------------------
// Team board (GET /api/app/team)
// ---------------------------------------------------------------------------

export interface BoardItem {
  id: string;
  /** Paperclip identifier like NOH-12, or null for No Hands-only tasks. */
  key: string | null;
  title: string;
  status: string;
  priority?: string | null;
  updated_at: string;
  source: "paperclip" | "nohands";
  tier?: number;
}

export interface BoardMember {
  id: string;
  kind: "agent" | "human";
  name: string;
  title: string | null;
  status: string | null;
  items: BoardItem[];
}

export interface TeamSnapshot {
  captured_at: string;
  company_id?: string | null;
  members: BoardMember[];
  unassigned: BoardItem[];
  counts: { open: number; in_progress: number; in_review: number; blocked: number };
  has_paperclip: boolean;
}

/** Contract: GET /api/app/team → TeamSnapshot (bots and humans alike). */
export function getTeam(): Promise<TeamSnapshot> {
  return request("/api/app/team");
}

// ---------------------------------------------------------------------------
// Account settings (GET/POST /api/app/settings)
// ---------------------------------------------------------------------------

export interface AccountSettings {
  /** IANA zone, e.g. "America/Los_Angeles". */
  tz: string;
  /** "HH:MM" 24h, or null when quiet hours are off. */
  quiet_hours_start: string | null;
  quiet_hours_end: string | null;
  /** "HH:MM" 24h, or null for no daily brief. */
  daily_brief_at: string | null;
  push_enabled: boolean;
}

/** Contract: GET /api/app/settings → AccountSettings. */
export function getSettings(): Promise<AccountSettings> {
  return request("/api/app/settings");
}

/** Contract: POST /api/app/settings { ...partial } → the updated settings
 *  (or { ok } — callers merge the patch locally either way). */
export function updateSettings(
  patch: Partial<AccountSettings>,
): Promise<Partial<AccountSettings> & { ok?: boolean }> {
  return request("/api/app/settings", { method: "POST", body: JSON.stringify(patch) });
}
