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

export function submitGoal(text: string): Promise<{ ok: true; id: string }> {
  return request("/api/app/goals", {
    method: "POST",
    body: JSON.stringify({ text }),
  });
}

export function getFeed(): Promise<FeedResponse> {
  return request("/api/app/feed");
}

export function decideApproval(
  approvalId: string,
  verdict: Verdict,
): Promise<{ ok: true }> {
  return request("/api/app/approvals/decide", {
    method: "POST",
    body: JSON.stringify({ approvalId, verdict }),
  });
}
