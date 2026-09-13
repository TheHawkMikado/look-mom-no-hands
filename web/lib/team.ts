import { sql } from "@/lib/db";
import { getPaperclipConnection, listTasks, type PaperclipConnection, type TaskRow } from "@/lib/db-tasks";
import { assertCloudWritable, capCloudText } from "@/lib/residency";
import { ISSUE_OPEN, PaperclipClient, type PcAgent, type PcIssue, type PcMember } from "@/lib/paperclip";

/**
 * Team boards: every member's work, humans and bots alike, in one view. The
 * owner never opens Paperclip; this is the window. A snapshot per account is
 * captured on each sync round (direct mode) or posted by the bridge, and
 * overlaid with the No Hands tasks that live only here (owner = a human
 * without a Paperclip seat, or the user's own decisions).
 *
 * Cloud-resident by construction: issue titles, statuses, owners and times.
 * Never descriptions or comments — those stay in Paperclip.
 */

export interface BoardItem {
  id: string;
  key: string | null; // NOH-12
  title: string;
  status: string;
  priority: string | null;
  updated_at: string;
  /** 'paperclip' or 'nohands' (a task that never reached Paperclip). */
  source: "paperclip" | "nohands";
  tier?: number;
}

export interface BoardMember {
  id: string;
  kind: "agent" | "human";
  name: string;
  title: string | null;
  /** Agent runtime status from Paperclip (idle/running/paused/error…). */
  status: string | null;
  items: BoardItem[];
}

export interface TeamSnapshot {
  captured_at: string;
  company_id: string | null;
  members: BoardMember[];
  /** Open issues with nobody assigned. */
  unassigned: BoardItem[];
  counts: { open: number; in_progress: number; in_review: number; blocked: number };
}

export interface RawBoard {
  agents: Pick<PcAgent, "id" | "name" | "role" | "title" | "status">[];
  members: PcMember[];
  issues: Pick<PcIssue, "id" | "identifier" | "title" | "status" | "priority" | "assigneeAgentId" | "assigneeUserId" | "updatedAt">[];
}

export function ensureTeamSchemaSQL(db = sql()) {
  return db`
    CREATE TABLE IF NOT EXISTS team_boards (
      email       text PRIMARY KEY,
      snapshot    jsonb NOT NULL,
      residency   text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      captured_at timestamptz NOT NULL DEFAULT now()
    )`;
}

const item = (i: RawBoard["issues"][number]): BoardItem => ({
  id: i.id,
  key: i.identifier ?? null,
  title: capCloudText(i.title, 200),
  status: i.status,
  priority: i.priority ?? null,
  updated_at: i.updatedAt,
  source: "paperclip",
});

const byRecent = (a: BoardItem, b: BoardItem) => (a.updated_at < b.updated_at ? 1 : -1);

/** Pure: raw Paperclip lists → the snapshot. Shared by direct mode and the bridge. */
export function buildSnapshot(raw: RawBoard, companyId: string | null, now = new Date()): TeamSnapshot {
  const open = raw.issues.filter((i) => (ISSUE_OPEN as readonly string[]).includes(i.status));
  const members: BoardMember[] = [];
  for (const a of raw.agents) {
    members.push({
      id: a.id,
      kind: "agent",
      name: a.name,
      title: a.title ?? a.role ?? null,
      status: a.status ?? null,
      items: open.filter((i) => i.assigneeAgentId === a.id).map(item).sort(byRecent),
    });
  }
  const seenUsers = new Set<string>();
  for (const m of raw.members) {
    if (m.principalType !== "user" || m.status !== "active") continue;
    const uid = m.user?.id ?? m.principalId;
    if (seenUsers.has(uid)) continue;
    seenUsers.add(uid);
    members.push({
      id: uid,
      kind: "human",
      name: m.user?.name || m.user?.email || uid,
      title: m.membershipRole ?? null,
      status: null,
      items: open.filter((i) => i.assigneeUserId === uid).map(item).sort(byRecent),
    });
  }
  const assigned = new Set(members.flatMap((m) => m.items.map((i) => i.id)));
  const unassigned = open.filter((i) => !assigned.has(i.id)).map(item).sort(byRecent);
  const count = (s: string) => open.filter((i) => i.status === s).length;
  return {
    captured_at: now.toISOString(),
    company_id: companyId,
    members,
    unassigned,
    counts: { open: open.length, in_progress: count("in_progress"), in_review: count("in_review"), blocked: count("blocked") },
  };
}

export async function storeSnapshot(email: string, snap: TeamSnapshot) {
  const row = assertCloudWritable({ kind: "team_board", residency: "cloud" as const, snapshot: snap });
  await sql()`
    INSERT INTO team_boards (email, snapshot, residency, captured_at)
    VALUES (${email.trim().toLowerCase()}, ${JSON.stringify(row.snapshot)}, ${row.residency}, ${snap.captured_at})
    ON CONFLICT (email) DO UPDATE SET snapshot = EXCLUDED.snapshot, captured_at = EXCLUDED.captured_at`;
}

/** Direct mode: pull the lists from Paperclip and store the snapshot. */
export async function captureDirect(email: string, conn: PaperclipConnection & { apiKey: string | null }) {
  const pc = new PaperclipClient({ url: conn.url, apiKey: conn.apiKey });
  const [agents, membersRes, issues] = await Promise.all([
    pc.listAgents(conn.company_id),
    pc.listMembers(conn.company_id).catch(() => ({ members: [] as PcMember[] })),
    pc.listIssues(conn.company_id, { status: ISSUE_OPEN.join(",") }),
  ]);
  const snap = buildSnapshot({ agents, members: membersRes.members ?? [], issues }, conn.company_id);
  await storeSnapshot(email, snap);
  return snap;
}

/** Bridge mode: the bridge fetched the lists and posted them. */
export async function storeRawBoard(email: string, raw: RawBoard) {
  const conn = await getPaperclipConnection(email);
  const snap = buildSnapshot(
    { agents: raw.agents ?? [], members: raw.members ?? [], issues: raw.issues ?? [] },
    conn?.company_id ?? null,
  );
  await storeSnapshot(email, snap);
  return snap;
}

/** The board the phone and the web page show: the last snapshot plus the
 *  No Hands tasks that live only here, grouped under their owners. */
export async function teamBoard(email: string): Promise<TeamSnapshot & { has_paperclip: boolean }> {
  const account = email.trim().toLowerCase();
  const [rows, conn, tasks] = await Promise.all([
    sql()<{ snapshot: TeamSnapshot | string; captured_at: Date }[]>`SELECT snapshot, captured_at FROM team_boards WHERE email = ${account}`,
    getPaperclipConnection(account),
    listTasks(account, { status: ["triaged", "dispatching", "in_progress", "awaiting_approval", "approved", "assigned", "needs_decision"], limit: 200 }),
  ]);
  const stored = rows[0]?.snapshot;
  const snap: TeamSnapshot = stored
    ? typeof stored === "string" ? (JSON.parse(stored) as TeamSnapshot) : stored
    : { captured_at: new Date(0).toISOString(), company_id: conn?.company_id ?? null, members: [], unassigned: [], counts: { open: 0, in_progress: 0, in_review: 0, blocked: 0 } };

  // Overlay: tasks for humans without a Paperclip seat, and the owner's own
  // decisions, become members/items of their own so nothing is invisible.
  const you: BoardMember = { id: "you", kind: "human", name: "You", title: "owner", status: null, items: [] };
  const humans = new Map<string, BoardMember>();
  for (const t of tasks) {
    if (t.owner_kind === "agent" && t.paperclip_issue_id) continue; // already on the agent's board
    const it = nhItem(t);
    if (t.owner_kind === "human" && t.owner_name) {
      const key = t.owner_name.toLowerCase();
      const m = humans.get(key) ?? { id: `human:${key}`, kind: "human", name: t.owner_name, title: "team", status: null, items: [] };
      m.items.push(it);
      humans.set(key, m);
    } else if (t.owner_kind === "agent") {
      // Dispatching or failed-to-dispatch: show under the agent it's meant for.
      const m = snap.members.find((x) => x.id === t.owner_ref);
      if (m) m.items.unshift(it);
      else snap.unassigned.unshift(it);
    } else {
      you.items.push(it);
    }
  }
  const members = [...snap.members];
  for (const m of humans.values()) {
    const existing = members.find((x) => x.kind === "human" && x.name.toLowerCase() === m.name.toLowerCase());
    if (existing) existing.items.push(...m.items);
    else members.push(m);
  }
  if (you.items.length > 0) members.unshift(you);
  return { ...snap, members, has_paperclip: !!conn };
}

function nhItem(t: TaskRow): BoardItem {
  return {
    id: t.id,
    key: t.paperclip_issue_key,
    title: t.title,
    status: t.status,
    priority: null,
    updated_at: new Date(t.updated_at).toISOString(),
    source: "nohands",
    tier: t.blast_tier,
  };
}
