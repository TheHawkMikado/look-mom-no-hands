import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { updatePaperclipAgents } from "@/lib/db-tasks";
import { appEmail } from "@/lib/appauth";
import { bridgeReport, type Observation } from "@/lib/tasks";

/** POST /api/app/bridge/report — { observations: Observation[], agents?: [...] } */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const body = (await req.json().catch(() => ({}))) as { observations?: Observation[]; agents?: unknown };
  await ensureSchema();
  if (Array.isArray(body.agents)) {
    await updatePaperclipAgents(
      email,
      (body.agents as { id: string; name: string; role: string; title?: string | null; capabilities?: string | null }[])
        .filter((a) => a && typeof a.id === "string")
        .map((a) => ({ id: a.id, name: a.name, role: a.role, title: a.title ?? null, capabilities: a.capabilities ?? null })),
    );
  }
  const n = await bridgeReport(email, Array.isArray(body.observations) ? body.observations : []);
  return NextResponse.json({ ok: true, advanced: n });
}
