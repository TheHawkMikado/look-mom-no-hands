import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getSession } from "@/lib/auth";
import { Lockup } from "@/components/Logo";
import { TeamBoard } from "@/components/TeamBoard";

export const metadata: Metadata = { title: "Team — Look Ma, No Hands" };
export const dynamic = "force-dynamic";

/** Every team member's board — humans and bots — from any device. Read-only:
 *  approvals happen on /status; this is where you see who is doing what. */
export default async function Team() {
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
        <a href="/status">Agents</a>
        <a href="/account">Account</a>
        {session.admin && <a href="/admin">Admin</a>}
        <span style={{ fontSize: 13, color: "var(--muted)" }}>{session.email}</span>
        <form action="/api/auth/logout" method="post" style={{ display: "inline" }}>
          <button className="linkish">Sign out</button>
        </form>
      </nav>

      <section style={{ borderTop: 0, paddingTop: 48 }}>
        <h2>Team</h2>
        <p className="dim">
          Everyone on your team and what they are working on — the agents and the humans,
          in one place. Anything marked “ready for you” is waiting on the Agents page.
        </p>
        <TeamBoard />
      </section>
    </div>
  );
}
