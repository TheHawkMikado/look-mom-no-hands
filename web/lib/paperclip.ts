/**
 * Paperclip REST client. Dependency-free on purpose: the same file is
 * imported by the Next.js service (direct mode) and by the bridge script that
 * runs next to a localhost Paperclip (`Scripts/paperclip/bridge.mjs`), so it
 * must not pull in Next, the database, or path aliases.
 *
 * Auth: Paperclip in local trusted mode needs no token; otherwise a long-lived
 * agent key or a run JWT goes in `Authorization: Bearer`.
 */

export interface PaperclipClientOptions {
  url: string;
  apiKey?: string | null;
  /** Forwarded on mutating calls made from inside a heartbeat. */
  runId?: string | null;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

export interface PcCompany {
  id: string;
  name: string;
}
export interface PcAgent {
  id: string;
  companyId: string;
  name: string;
  role: string;
  title: string | null;
  capabilities: string | null;
  status: string;
  adapterType: string;
}
export interface PcIssue {
  id: string;
  companyId: string;
  identifier: string | null;
  title: string;
  description: string | null;
  status: string;
  priority: string | null;
  assigneeAgentId: string | null;
  assigneeUserId: string | null;
  createdAt: string;
  updatedAt: string;
}
export interface PcMember {
  id: string;
  principalType: string;
  principalId: string;
  status: string;
  membershipRole: string;
  user?: { id: string; email: string | null; name: string | null } | null;
}
export interface PcComment {
  id: string;
  issueId: string;
  authorAgentId: string | null;
  authorUserId: string | null;
  body: string;
  createdAt: string;
}
export interface PcRun {
  id: string;
  agentId: string;
  status: string;
  createdAt: string;
  finishedAt: string | null;
  error: string | null;
}

export class PaperclipError extends Error {
  constructor(public readonly status: number, message: string, public readonly body?: unknown) {
    super(message);
    this.name = "PaperclipError";
  }
}

function errorMessage(json: unknown): string | null {
  if (!json || typeof json !== "object") return null;
  const e = (json as { error?: unknown; message?: unknown }).error ?? (json as { message?: unknown }).message;
  if (e == null) return null;
  return typeof e === "string" ? e : JSON.stringify(e);
}

export class PaperclipClient {
  private readonly base: string;
  private readonly key: string | null;
  private readonly runId: string | null;
  private readonly f: typeof fetch;
  private readonly timeoutMs: number;

  constructor(o: PaperclipClientOptions) {
    this.base = o.url.replace(/\/+$/, "");
    this.key = o.apiKey ?? null;
    this.runId = o.runId ?? null;
    this.f = o.fetchImpl ?? fetch;
    this.timeoutMs = o.timeoutMs ?? 15_000;
  }

  get url() {
    return this.base;
  }

  private async req<T>(method: string, path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (body !== undefined) headers["content-type"] = "application/json";
    if (this.key) headers.authorization = `Bearer ${this.key}`;
    if (this.runId && method !== "GET") headers["x-paperclip-run-id"] = this.runId;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      const res = await this.f(`${this.base}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: ctrl.signal,
      });
      const text = await res.text();
      let json: unknown = null;
      try {
        json = text ? JSON.parse(text) : null;
      } catch {
        json = text;
      }
      if (!res.ok) {
        throw new PaperclipError(res.status, errorMessage(json) ?? `${method} ${path} → ${res.status}`, json);
      }
      return json as T;
    } finally {
      clearTimeout(timer);
    }
  }

  // Health / identity
  health() {
    return this.req<{ ok?: boolean; status?: string }>("GET", "/api/health");
  }
  me() {
    return this.req<PcAgent>("GET", "/api/agents/me");
  }

  // Companies
  listCompanies() {
    return this.req<PcCompany[]>("GET", "/api/companies");
  }
  createCompany(name: string, description = "") {
    return this.req<PcCompany>("POST", "/api/companies", { name, description });
  }

  // Agents
  listAgents(companyId: string) {
    return this.req<PcAgent[]>("GET", `/api/companies/${companyId}/agents`);
  }
  createAgent(companyId: string, a: Record<string, unknown>) {
    return this.req<PcAgent>("POST", `/api/companies/${companyId}/agents`, a);
  }
  updateAgent(agentId: string, patch: Record<string, unknown>) {
    return this.req<PcAgent>("PATCH", `/api/agents/${agentId}`, patch);
  }
  /** Long-lived agent key. Paperclip returns it once, as `token`. */
  createAgentKey(agentId: string, name = "nohands") {
    return this.req<{ token: string; [k: string]: unknown }>("POST", `/api/agents/${agentId}/keys`, { name });
  }
  /** Issues assigned to the authenticated agent that still need work. */
  inboxLite() {
    return this.req<{ issues?: PcIssue[]; [k: string]: unknown } | PcIssue[]>("GET", "/api/agents/me/inbox-lite");
  }
  invokeHeartbeat(agentId: string, reason = "on_demand") {
    return this.req<unknown>("POST", `/api/agents/${agentId}/heartbeat/invoke`, { reason });
  }

  /** Human members of the company (board users). */
  listMembers(companyId: string) {
    return this.req<{ members: PcMember[] }>("GET", `/api/companies/${companyId}/members`);
  }

  // Issues
  listIssues(companyId: string, q: { status?: string; assigneeAgentId?: string } = {}) {
    const p = new URLSearchParams();
    if (q.status) p.set("status", q.status);
    if (q.assigneeAgentId) p.set("assigneeAgentId", q.assigneeAgentId);
    const qs = p.toString();
    return this.req<PcIssue[]>("GET", `/api/companies/${companyId}/issues${qs ? `?${qs}` : ""}`);
  }
  getIssue(issueId: string) {
    return this.req<PcIssue & Record<string, unknown>>("GET", `/api/issues/${issueId}`);
  }
  createIssue(companyId: string, issue: Record<string, unknown>) {
    return this.req<PcIssue>("POST", `/api/companies/${companyId}/issues`, issue);
  }
  updateIssue(issueId: string, patch: Record<string, unknown>) {
    return this.req<PcIssue>("PATCH", `/api/issues/${issueId}`, patch);
  }
  checkout(issueId: string, agentId: string, expectedStatuses = ["todo", "backlog", "blocked", "in_review", "in_progress"]) {
    return this.req<PcIssue>("POST", `/api/issues/${issueId}/checkout`, { agentId, expectedStatuses });
  }
  listComments(issueId: string) {
    return this.req<PcComment[]>("GET", `/api/issues/${issueId}/comments`);
  }
  addComment(issueId: string, body: string) {
    return this.req<PcComment>("POST", `/api/issues/${issueId}/comments`, { body });
  }
  listIssueRuns(issueId: string) {
    return this.req<PcRun[]>("GET", `/api/issues/${issueId}/runs`);
  }
}

/** The draft an agent left on an issue, if any: the newest comment authored
 *  by an agent. Pure so the sync loop and the bridge share one definition of
 *  "the draft is ready". */
export function latestAgentComment(comments: PcComment[]): PcComment | null {
  const byAgent = comments.filter((c) => c.authorAgentId);
  if (byAgent.length === 0) return null;
  return byAgent.reduce((a, b) => (a.createdAt > b.createdAt ? a : b));
}

/** Issue statuses that are still someone's work. */
export const ISSUE_OPEN = ["backlog", "todo", "in_progress", "in_review", "blocked"] as const;

/** Paperclip issue statuses that mean "the agent has produced something". */
export const ISSUE_DELIVERED = new Set(["in_review", "done"]);
export const ISSUE_FAILED = new Set(["cancelled", "canceled", "blocked"]);
