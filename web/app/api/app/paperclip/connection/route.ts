import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import {
  deletePaperclipConnection,
  getPaperclipConnection,
  setPaperclipConnection,
  type PaperclipAgentRef,
} from "@/lib/db-tasks";
import { appEmail } from "@/lib/appauth";
import { PaperclipClient } from "@/lib/paperclip";

/**
 * The Paperclip connection — the one setting that turns the cloud brain on.
 *
 * GET    → status (never the key)
 * POST   → { url, apiKey?, companyId, mode?: 'direct'|'bridge', agents? }
 *          direct: this service verifies it can reach the URL and lists agents;
 *          bridge: the bridge on the user's machine supplies the agent list.
 * DELETE → remove it. Delegation stops; nothing else changes. This is how a
 *          user opts out.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  const c = await getPaperclipConnection(email);
  if (!c) return NextResponse.json({ connected: false });
  return NextResponse.json({
    connected: true,
    url: c.url,
    mode: c.mode,
    company_id: c.company_id,
    agents: c.agents,
    has_key: !!c.apiKey,
    created_at: c.created_at,
    last_seen_at: c.last_seen_at,
  });
}

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const url = String(body.url ?? "").trim().replace(/\/+$/, "");
  const companyId = String(body.companyId ?? "").trim();
  const apiKey = body.apiKey ? String(body.apiKey) : null;
  const mode = body.mode === "bridge" ? "bridge" : "direct";
  if (!/^https?:\/\//.test(url) || !companyId) {
    return NextResponse.json({ error: "url and companyId required" }, { status: 400 });
  }

  let agents: PaperclipAgentRef[] = Array.isArray(body.agents) ? (body.agents as PaperclipAgentRef[]) : [];
  if (mode === "direct") {
    try {
      const pc = new PaperclipClient({ url, apiKey, timeoutMs: 8000 });
      agents = (await pc.listAgents(companyId)).map(toRef);
    } catch (e) {
      return NextResponse.json(
        { error: `could not reach Paperclip at ${url}: ${e instanceof Error ? e.message : e}`, hint: "If Paperclip runs on your own machine, register it in bridge mode from Scripts/paperclip/bootstrap.mjs." },
        { status: 502 },
      );
    }
  }
  await ensureSchema();
  await setPaperclipConnection(email, { url, mode, apiKey, companyId, agents });
  return NextResponse.json({ ok: true, mode, agents });
}

export async function DELETE(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  const removed = await deletePaperclipConnection(email);
  return NextResponse.json({ ok: true, removed });
}

export function toRef(a: { id: string; name: string; role: string; title?: string | null; capabilities?: string | null }): PaperclipAgentRef {
  return { id: a.id, name: a.name, role: a.role, title: a.title ?? null, capabilities: a.capabilities ?? null };
}
