"use client";

import { useCallback, useEffect, useState } from "react";

/**
 * Every member's board — humans and bots — polled every 10s. One card per
 * member, items newest-first, status as a pill. Read-only on purpose: you
 * approve from the feed; here you just see who is doing what.
 */

interface Item {
  id: string;
  key: string | null;
  title: string;
  status: string;
  priority: string | null;
  updated_at: string;
  source: "paperclip" | "nohands";
  tier?: number;
}
interface Member {
  id: string;
  kind: "agent" | "human";
  name: string;
  title: string | null;
  status: string | null;
  items: Item[];
}
interface Board {
  captured_at: string;
  members: Member[];
  unassigned: Item[];
  counts: { open: number; in_progress: number; in_review: number; blocked: number };
  has_paperclip: boolean;
}

const STATUS_LABEL: Record<string, string> = {
  backlog: "Backlog",
  todo: "To do",
  in_progress: "Working",
  in_review: "Ready for you",
  blocked: "Blocked",
  done: "Done",
  cancelled: "Cancelled",
  triaged: "Triaged",
  dispatching: "Handing off",
  awaiting_approval: "Needs approval",
  approved: "Approved",
  assigned: "Assigned",
  needs_decision: "Your call",
  failed: "Failed",
};
const STATUS_PILL: Record<string, string> = {
  in_review: "pill warn",
  awaiting_approval: "pill warn",
  needs_decision: "pill warn",
  blocked: "pill bad",
  failed: "pill bad",
  done: "pill good",
  approved: "pill good",
};

function ago(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  if (!Number.isFinite(ms) || ms < 0) return "";
  const m = Math.round(ms / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
}

export function TeamBoard() {
  const [board, setBoard] = useState<Board | null>(null);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    try {
      const res = await fetch("/api/status/team", { cache: "no-store" });
      if (!res.ok) throw new Error(String(res.status));
      setBoard(await res.json());
      setError("");
    } catch {
      setError("Can’t reach the server — retrying…");
    }
  }, []);

  useEffect(() => {
    load();
    const timer = setInterval(() => {
      if (!document.hidden) load();
    }, 10000);
    const onVisible = () => {
      if (!document.hidden) load();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [load]);

  if (board === null) return <p className="dim">Loading…</p>;

  const captured = new Date(board.captured_at).getTime() > 0 ? ago(board.captured_at) : null;

  return (
    <div>
      {error && <p className="err" style={{ textAlign: "left" }}>{error}</p>}
      {!board.has_paperclip && (
        <p className="dim">
          No team connected yet. Run <code>Scripts/paperclip/bootstrap.mjs</code> to hire your first agents;
          until then this shows only what’s waiting on you.
        </p>
      )}
      <div className="facts">
        <Stat label="Open" value={board.counts.open} />
        <Stat label="Working" value={board.counts.in_progress} />
        <Stat label="Ready for you" value={board.counts.in_review} />
        <Stat label="Blocked" value={board.counts.blocked} />
        {captured && <span className="dim small" style={{ alignSelf: "center" }}>snapshot {captured}</span>}
      </div>

      <div className="grid" style={{ marginTop: 20 }}>
        {board.members.map((m) => (
          <MemberCard key={m.id} m={m} />
        ))}
        {board.unassigned.length > 0 && (
          <MemberCard m={{ id: "unassigned", kind: "human", name: "Unassigned", title: "nobody has picked these up", status: null, items: board.unassigned }} />
        )}
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div className="stat">
      <div className="stat-value">{value}</div>
      <div className="stat-label">{label}</div>
    </div>
  );
}

function MemberCard({ m }: { m: Member }) {
  return (
    <div className="card">
      <div className="row-between">
        <div>
          <h3 style={{ marginBottom: 2 }}>
            {m.kind === "agent" ? "🤖 " : "🧑 "}
            {m.name}
          </h3>
          <p className="small">{m.title ?? (m.kind === "agent" ? "agent" : "team")}</p>
        </div>
        {m.status && <span className={m.status === "error" ? "pill bad" : m.status === "running" ? "pill good" : "pill dim"}>{m.status}</span>}
      </div>
      {m.items.length === 0 ? (
        <p className="dim small" style={{ marginTop: 12 }}>Nothing open.</p>
      ) : (
        <ul style={{ listStyle: "none", padding: 0, margin: "12px 0 0" }}>
          {m.items.map((it) => (
            <li key={it.id} style={{ padding: "8px 0", borderTop: "1px solid var(--line)" }}>
              <div className="row-between" style={{ gap: 8 }}>
                <span style={{ fontSize: 14 }}>
                  {it.key && <span className="dim small" style={{ marginRight: 6 }}>{it.key}</span>}
                  {it.title}
                </span>
                <span className={STATUS_PILL[it.status] ?? "pill dim"}>{STATUS_LABEL[it.status] ?? it.status}</span>
              </div>
              <div className="dim small" style={{ marginTop: 2 }}>
                {ago(it.updated_at)}
                {it.priority && it.priority !== "medium" ? ` · ${it.priority}` : ""}
                {typeof it.tier === "number" && it.tier >= 2 ? ` · tier ${it.tier}` : ""}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
