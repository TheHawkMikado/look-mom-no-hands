import { NextRequest, NextResponse } from "next/server";
import { getSession, setPostLoginNext } from "@/lib/auth";
import { createAppToken, ensureSchema } from "@/lib/db";

/**
 * GET /app/login — the target the macOS app opens in the browser to sign in.
 *
 * If the visitor already has a web session, we mint a per-device **app bearer
 * token** and hand it to the app via its custom URL scheme
 * (`lookmomnohands://auth?token=…`). If not, we remember to come back here and
 * send them through the normal Google/Apple/email login first — so the app
 * reuses exactly the same accounts as the site, and access is tied to who signs
 * in rather than a shareable key.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const site = process.env.SITE_URL ?? req.nextUrl.origin;
  const session = await getSession();

  if (!session) {
    await setPostLoginNext("/app/login");
    return NextResponse.redirect(`${site}/login`);
  }

  await ensureSchema();
  const token = await createAppToken(session.email, null);
  const scheme = `lookmomnohands://auth?token=${encodeURIComponent(token)}`;

  // An HTML page rather than a bare 3xx: browsers open custom-scheme URLs more
  // reliably from a real navigation, and this gives a visible fallback link if
  // the OS doesn't launch the app automatically.
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="0;url=${scheme}">
<title>Returning to Look Ma, No Hands</title>
<style>
  body{font-family:-apple-system,system-ui,sans-serif;background:#F4F1EA;color:#2b2b2b;
       display:grid;place-items:center;min-height:100vh;margin:0;text-align:center}
  .card{max-width:420px;padding:32px}
  h1{font-size:22px;margin:0 0 8px}p{color:#6b6b6b;line-height:1.5}
  a.btn{display:inline-block;margin-top:16px;padding:12px 20px;border-radius:10px;
        background:#2b2b2b;color:#fff;text-decoration:none;font-weight:600}
</style></head>
<body><div class="card">
  <h1>Signed in as ${escapeHtml(session.email)}</h1>
  <p>Returning you to the app… if it doesn't open automatically, click below.</p>
  <a class="btn" href="${scheme}">Open Look Ma, No Hands</a>
</div>
<script>location.href=${JSON.stringify(scheme)}</script>
</body></html>`;

  return new NextResponse(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string,
  );
}
