import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getSession } from "@/lib/auth";
import { Lockup } from "@/components/Logo";
import { StatusFeed } from "@/components/StatusFeed";

export const metadata: Metadata = { title: "Agents — Look Ma, No Hands" };
export const dynamic = "force-dynamic";

/** Live agent activity for the signed-in account, from any device — the phone
 *  page you glance at while the Mac works. The feed itself is a client component
 *  that polls every 5s; this shell just gates on the session. */
export default async function Status() {
  const session = await getSession();
  if (!session) redirect("/login");

  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        <a href="/account">Account</a>
        {session.admin && <a href="/admin">Admin</a>}
        <span style={{ fontSize: 13, color: "var(--muted)" }}>{session.email}</span>
        <form action="/api/auth/logout" method="post" style={{ display: "inline" }}>
          <button className="linkish">Sign out</button>
        </form>
      </nav>

      <section style={{ borderTop: 0, paddingTop: 48 }}>
        <h2>Agents</h2>
        <p className="dim">
          What your agents are doing right now, refreshed every few seconds. Anything
          that needs your say-so waits at the top until you approve or deny it.
        </p>
        <StatusFeed />
      </section>
    </div>
  );
}
