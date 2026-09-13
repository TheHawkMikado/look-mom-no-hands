import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { deleteIntegration, describeIntegration, isProvider, PROVIDER_FIELDS, setIntegration, validateConfig } from "@/lib/integrations";

/**
 * /api/app/integrations/:provider — ghl | vapi
 *
 * GET    → { connected, provider, config } — secrets shown as booleans only
 * POST   → the provider's config, e.g.
 *          ghl:  { api_key, location_id, from_number?, from_email? }
 *          vapi: { api_key, phone_number_id, assistant_id?, webhook_secret? }
 *          Stored encrypted (lib/crypto). Replaces the previous config.
 * DELETE → remove it; the feature that needed it degrades to "not
 *          configured" receipts, nothing else changes.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const noStore = { headers: { "cache-control": "no-store" } };

export async function GET(req: NextRequest, ctx: { params: Promise<{ provider: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { provider } = await ctx.params;
  if (!isProvider(provider)) return NextResponse.json({ error: "unknown provider", providers: Object.keys(PROVIDER_FIELDS) }, { status: 404 });
  await ensureSchema();
  return NextResponse.json({ ...(await describeIntegration(email, provider)), fields: PROVIDER_FIELDS[provider] }, noStore);
}

export async function POST(req: NextRequest, ctx: { params: Promise<{ provider: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { provider } = await ctx.params;
  if (!isProvider(provider)) return NextResponse.json({ error: "unknown provider", providers: Object.keys(PROVIDER_FIELDS) }, { status: 404 });
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const v = validateConfig(provider, body);
  if ("error" in v) return NextResponse.json({ error: v.error, fields: PROVIDER_FIELDS[provider] }, { status: 400 });
  await ensureSchema();
  await setIntegration(email, provider, v.config);
  return NextResponse.json({ ok: true, ...(await describeIntegration(email, provider)) }, noStore);
}

export async function DELETE(req: NextRequest, ctx: { params: Promise<{ provider: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { provider } = await ctx.params;
  if (!isProvider(provider)) return NextResponse.json({ error: "unknown provider" }, { status: 404 });
  await ensureSchema();
  return NextResponse.json({ ok: true, removed: await deleteIntegration(email, provider) });
}
