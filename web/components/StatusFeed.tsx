"use client";

import { useCallback, useEffect, useState } from "react";

/**
 * The live feed on /status: polls /api/status/feed every 5s, surfaces pending
 * approvals prominently with Approve/Deny (POST /api/status/decide), and lists
 * recent agent activity newest-first. Polling rather than push keeps this a
 * plain page that works anywhere the owner is signed in — phone included.
 */

interface FeedEvent {
  id: string;
  kind: string;
  title: string;
  detail: string;
  approvalId: string | null;
  createdAt: string;
}

const KIND_LABEL: Record<string, string> = {
  goal_started: "Started",
  goal_progress: "Working",
  needs_approval: "Needs approval",
  goal_done: "Done",
  goal_failed: "Failed",
};

const KIND_PILL: Record<string, string> = {
  goal_done: "pill good",
  goal_failed: "pill bad",
  needs_approval: "pill warn",
  goal_started: "pill dim",
  goal_progress: "pill dim",
};

function when(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const today = new Date().toDateString() === d.toDateString();
  return today
    ? d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : d.toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

export function StatusFeed() {
  const [events, setEvents] = useState<FeedEvent[] | null>(null);
  const [verdicts, setVerdicts] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const res = await fetch("/api/status/feed", { cache: "no-store" });
      if (!res.ok) throw new Error(String(res.status));
      const data = await res.json();
      setEvents(Array.isArray(data.events) ? data.events : []);
      setVerdicts(data.verdicts ?? {});
      setError("");
    } catch {
      // Keep showing the last good feed; the next tick retries.
      setError("Can’t reach the server — retrying…");
    }
  }, []);

  useEffect(() => {
    load();
    const timer = setInterval(load, 5000);
    return () => clearInterval(timer);
  }, [load]);

  async function decide(approvalId: string, verdict: "approve" | "deny") {
    setBusy(approvalId);
    try {
      await fetch("/api/status/decide", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ approvalId, verdict }),
      });
      await load();
    } finally {
      setBusy(null);
    }
  }

  if (events === null) return <p className="dim">Loading…</p>;

  // Pending = a needs_approval event whose approvalId has no verdict yet.
  const seen = new Set<string>();
  const pending = events.filter((e) => {
    if (e.kind !== "needs_approval" || !e.approvalId || verdicts[e.approvalId]) return false;
    if (seen.has(e.approvalId)) return false;
    seen.add(e.approvalId);
    return true;
  });

  return (
    <div>
      {error && <p className="err" style={{ textAlign: "left" }}>{error}</p>}

      {pending.map((e) => (
        <div
          key={e.approvalId}
          className="panel-card"
          style={{ borderColor: "#f0aa3c", marginBottom: 16 }}
        >
          <div className="row-between">
            <div>
              <span className="pill warn">Waiting for you</span>
              <h3 style={{ margin: "10px 0 4px" }}>{e.title || "An agent needs your approval"}</h3>
              {e.detail && <p className="dim" style={{ margin: 0 }}>{e.detail}</p>}
              <p className="dim small" style={{ margin: "6px 0 0" }}>{when(e.createdAt)}</p>
            </div>
          </div>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 14 }}>
            <button
              className="btn btn-primary"
              disabled={busy !== null}
              onClick={() => decide(e.approvalId!, "approve")}
            >
              {busy === e.approvalId ? "…" : "Approve"}
            </button>
            <button
              className="btn btn-ghost"
              disabled={busy !== null}
              onClick={() => decide(e.approvalId!, "deny")}
            >
              Deny
            </button>
          </div>
        </div>
      ))}

      {events.length === 0 ? (
        <div className="card" style={{ marginTop: 8 }}>
          <h3>Nothing yet</h3>
          <p>
            When the Mac app runs an agent, its progress shows up here — and anything
            that needs your say-so waits for an Approve.
          </p>
        </div>
      ) : (
        <div className="panel-card">
          <table className="table">
            <tbody>
              {events.map((e) => {
                const settled = e.approvalId ? verdicts[e.approvalId] : undefined;
                return (
                  <tr key={e.id}>
                    <td style={{ whiteSpace: "nowrap", verticalAlign: "top" }}>
                      {e.kind === "needs_approval" && settled ? (
                        <span className={settled === "approve" ? "pill good" : "pill bad"}>
                          {settled === "approve" ? "Approved" : "Denied"}
                        </span>
                      ) : (
                        <span className={KIND_PILL[e.kind] ?? "pill"}>
                          {KIND_LABEL[e.kind] ?? e.kind}
                        </span>
                      )}
                    </td>
                    <td>
                      <strong>{e.title}</strong>
                      {e.detail && (
                        <div className="dim small" style={{ marginTop: 2 }}>{e.detail}</div>
                      )}
                    </td>
                    <td className="dim small" style={{ whiteSpace: "nowrap", textAlign: "right", verticalAlign: "top" }}>
                      {when(e.createdAt)}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
