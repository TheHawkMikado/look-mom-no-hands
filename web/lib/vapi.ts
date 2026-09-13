/**
 * Vapi REST client for outbound calls (SPEC.md §5.5; DECISIONS.md
 * 2026-09-13 "Outbound calls go through Vapi"). Pure and dependency-free so
 * the call-building and the end-of-call parsing can be unit-tested without
 * a network.
 *
 * Shapes: `POST /call` with `{ phoneNumberId, customer: { number }, assistant
 * : { … } }` (a transient assistant built per call) and the server-URL
 * messages Vapi posts back (`message.type` of `status-update` and
 * `end-of-call-report`, the latter carrying `analysis.summary`,
 * `analysis.structuredData`, `analysis.successEvaluation`, `durationSeconds`
 * and `cost`). The docs host was unreachable from the build box, so these
 * are the documented v1 shapes as widely used rather than re-verified today;
 * the parser is defensive about optional fields for that reason.
 */

export const VAPI_BASE = "https://api.vapi.ai";

export interface VapiClientOptions {
  apiKey: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

export class VapiError extends Error {
  constructor(public readonly status: number, message: string, public readonly body?: unknown) {
    super(message);
    this.name = "VapiError";
  }
}

export interface VapiCall {
  id: string;
  status: string;
  [k: string]: unknown;
}

export class VapiClient {
  private readonly key: string;
  private readonly f: typeof fetch;
  private readonly timeoutMs: number;

  constructor(o: VapiClientOptions) {
    this.key = o.apiKey;
    this.f = o.fetchImpl ?? fetch;
    this.timeoutMs = o.timeoutMs ?? 15_000;
  }

  private async req<T>(method: string, path: string, body?: unknown): Promise<T> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      const res = await this.f(`${VAPI_BASE}${path}`, {
        method,
        headers: {
          accept: "application/json",
          authorization: `Bearer ${this.key}`,
          ...(body !== undefined ? { "content-type": "application/json" } : {}),
        },
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
        const msg = json && typeof json === "object" && "message" in json ? String((json as { message: unknown }).message) : `${method} ${path} → ${res.status}`;
        throw new VapiError(res.status, msg, json);
      }
      return json as T;
    } finally {
      clearTimeout(timer);
    }
  }

  createCall(body: OutboundCallBody) {
    return this.req<VapiCall>("POST", "/call", body);
  }
  getCall(id: string) {
    return this.req<VapiCall>("GET", `/call/${id}`);
  }
}

// MARK: - Building the call

export interface OutboundCallSpec {
  phoneNumberId: string;
  to: string;
  assistantName: string;
  systemPrompt: string;
  firstMessage: string;
  model: { provider: string; model: string };
  serverUrl: string | null;
  serverSecret: string | null;
  metadata: Record<string, string>;
  maxDurationSeconds?: number;
}

export interface OutboundCallBody {
  phoneNumberId: string;
  customer: { number: string };
  assistant: Record<string, unknown>;
  metadata: Record<string, string>;
}

/** The structured outcome we ask Vapi's analysis step for. Deliberately
 *  small and free of contact details: this is what gets stored (§4.3). */
export const OUTCOME_SCHEMA = {
  type: "object",
  properties: {
    outcome: { type: "string", enum: ["done", "partial", "failed", "needs_owner"], description: "done = the goal was achieved; partial = some of it; failed = could not; needs_owner = the other party needs the owner to decide something" },
    summary: { type: "string", description: "Two sentences, no phone numbers or addresses." },
    amount_cents: { type: "integer", description: "Any price or commitment quoted, in cents; 0 if none." },
    next_step: { type: "string", description: "What should happen next, if anything." },
    confirmation_ref: { type: "string", description: "A booking or reference code, if one was given." },
  },
  required: ["outcome", "summary"],
} as const;

export function buildOutboundCall(s: OutboundCallSpec): OutboundCallBody {
  const assistant: Record<string, unknown> = {
    name: s.assistantName,
    firstMessage: s.firstMessage,
    model: {
      provider: s.model.provider,
      model: s.model.model,
      messages: [{ role: "system", content: s.systemPrompt }],
    },
    endCallFunctionEnabled: true,
    maxDurationSeconds: s.maxDurationSeconds ?? 600,
    analysisPlan: {
      summaryPrompt: "Summarise the call in two sentences for the person who asked for it. Never include phone numbers, addresses or card details.",
      structuredDataSchema: OUTCOME_SCHEMA,
      successEvaluationRubric: "PassFail",
    },
    // No transcript or recording is stored on our side (§4.3); Vapi's own
    // retention is the account's setting there.
    artifactPlan: { recordingEnabled: false },
  };
  if (s.serverUrl) {
    assistant.server = { url: s.serverUrl, ...(s.serverSecret ? { secret: s.serverSecret } : {}) };
    assistant.serverMessages = ["status-update", "end-of-call-report"];
  }
  return {
    phoneNumberId: s.phoneNumberId,
    customer: { number: s.to },
    assistant,
    metadata: s.metadata,
  };
}

// MARK: - Parsing what Vapi posts back

export interface CallOutcome {
  outcome: "done" | "partial" | "failed" | "needs_owner";
  summary: string;
  amount_cents: number;
  next_step: string | null;
  confirmation_ref: string | null;
  success: boolean | null;
  ended_reason: string | null;
  duration_seconds: number | null;
}

export type ServerMessage =
  | { type: "status-update"; callId: string | null; status: string | null }
  | { type: "end-of-call-report"; callId: string | null; costCents: number; outcome: CallOutcome }
  | { type: "other"; callId: string | null; raw: string };

const str = (v: unknown, cap = 1000): string | null => (typeof v === "string" && v.trim() ? v.trim().slice(0, cap) : null);

/** Turn a server-URL webhook body into something the app can act on. Never
 *  throws on a strange body: an unknown message is `other`. */
export function parseServerMessage(body: unknown): ServerMessage {
  const msg = ((body as { message?: unknown })?.message ?? body ?? {}) as Record<string, unknown>;
  const call = (msg.call ?? {}) as Record<string, unknown>;
  const callId = str(call.id, 128);
  const type = str(msg.type, 64);
  if (type === "status-update") return { type, callId, status: str(msg.status, 64) };
  if (type === "end-of-call-report") {
    const analysis = (msg.analysis ?? {}) as Record<string, unknown>;
    const sd = (analysis.structuredData ?? {}) as Record<string, unknown>;
    const outcomeWord = str(sd.outcome, 32);
    const successRaw = analysis.successEvaluation;
    const success =
      typeof successRaw === "boolean" ? successRaw
      : typeof successRaw === "string" ? (/^(true|pass)$/i.test(successRaw) ? true : /^(false|fail)$/i.test(successRaw) ? false : null)
      : null;
    const cost = typeof msg.cost === "number" ? msg.cost : Number(msg.cost ?? 0) || 0;
    const duration = typeof msg.durationSeconds === "number" ? msg.durationSeconds : Number(msg.durationSeconds ?? NaN);
    const outcome: CallOutcome = {
      outcome: outcomeWord === "done" || outcomeWord === "partial" || outcomeWord === "failed" || outcomeWord === "needs_owner"
        ? outcomeWord
        : success === true ? "done" : success === false ? "failed" : "partial",
      summary: str(sd.summary) ?? str(analysis.summary) ?? "(no summary)",
      amount_cents: Math.max(0, Math.round(Number(sd.amount_cents ?? 0) || 0)),
      next_step: str(sd.next_step, 300),
      confirmation_ref: str(sd.confirmation_ref, 64),
      success,
      ended_reason: str(msg.endedReason, 64),
      duration_seconds: Number.isFinite(duration) ? Math.round(duration) : null,
    };
    return { type, callId, costCents: Math.round(cost * 100), outcome };
  }
  return { type: "other", callId, raw: type ?? "?" };
}
