/**
 * GoHighLevel (LeadConnector REST v2) client — SMS and email tickets to
 * humans on the team (SPEC.md §11). Dependency-free and pure like
 * lib/paperclip.ts so it can be unit-tested with a fake fetch.
 *
 * Shapes follow the published v2 API: contacts are upserted by email/phone
 * under a location, and messages go out through `conversations/messages`
 * with a `type` of SMS or Email. The docs host was unreachable from the
 * build box, so the endpoint paths below are the widely used ones rather
 * than freshly re-verified; a 4xx from GHL surfaces as a GhlError with the
 * body, which is enough to correct a path in one edit.
 */

export const GHL_BASE = "https://services.leadconnectorhq.com";
const CONTACTS_VERSION = "2021-07-28";
const CONVERSATIONS_VERSION = "2021-04-15";

export interface GhlClientOptions {
  apiKey: string;
  locationId: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

export class GhlError extends Error {
  constructor(public readonly status: number, message: string, public readonly body?: unknown) {
    super(message);
    this.name = "GhlError";
  }
}

export interface GhlContact {
  id: string;
}

export interface GhlSendResult {
  conversationId: string | null;
  messageId: string | null;
}

export class GhlClient {
  private readonly key: string;
  private readonly location: string;
  private readonly f: typeof fetch;
  private readonly timeoutMs: number;

  constructor(o: GhlClientOptions) {
    this.key = o.apiKey;
    this.location = o.locationId;
    this.f = o.fetchImpl ?? fetch;
    this.timeoutMs = o.timeoutMs ?? 15_000;
  }

  private async req<T>(method: string, path: string, version: string, body?: unknown): Promise<T> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      const res = await this.f(`${GHL_BASE}${path}`, {
        method,
        headers: {
          accept: "application/json",
          authorization: `Bearer ${this.key}`,
          version,
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
        throw new GhlError(res.status, msg, json);
      }
      return json as T;
    } finally {
      clearTimeout(timer);
    }
  }

  /** Find-or-create by email/phone. GHL dedupes on either under the location. */
  async upsertContact(c: { email?: string | null; phone?: string | null; name?: string | null }): Promise<GhlContact> {
    const body: Record<string, unknown> = { locationId: this.location };
    if (c.email) body.email = c.email;
    if (c.phone) body.phone = c.phone;
    if (c.name) body.name = c.name;
    const out = await this.req<{ contact?: { id: string }; id?: string }>("POST", "/contacts/upsert", CONTACTS_VERSION, body);
    const id = out.contact?.id ?? out.id;
    if (!id) throw new GhlError(502, "GHL upsert returned no contact id", out);
    return { id };
  }

  async sendSms(contactId: string, message: string, fromNumber?: string | null): Promise<GhlSendResult> {
    const out = await this.req<{ conversationId?: string; messageId?: string }>("POST", "/conversations/messages", CONVERSATIONS_VERSION, {
      type: "SMS",
      contactId,
      message,
      ...(fromNumber ? { fromNumber } : {}),
    });
    return { conversationId: out.conversationId ?? null, messageId: out.messageId ?? null };
  }

  async sendEmail(contactId: string, m: { subject: string; text: string; html?: string; emailFrom?: string | null }): Promise<GhlSendResult> {
    const out = await this.req<{ conversationId?: string; messageId?: string }>("POST", "/conversations/messages", CONVERSATIONS_VERSION, {
      type: "Email",
      contactId,
      subject: m.subject,
      html: m.html ?? `<pre style="font-family:inherit;white-space:pre-wrap">${escapeHtml(m.text)}</pre>`,
      message: m.text,
      ...(m.emailFrom ? { emailFrom: m.emailFrom } : {}),
    });
    return { conversationId: out.conversationId ?? null, messageId: out.messageId ?? null };
  }
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c] ?? c);
}
