import { awaitingReview, listSops, type Candidate } from "@/lib/brain";
import { adminBrainApprove, adminBrainReject } from "./brain-actions";

/** The Shared Brain review queue on /admin: candidates the user consented to,
 *  scrubbed, waiting for a human to approve (publish) or reject. */
export default async function BrainReview() {
  let queue: Awaited<ReturnType<typeof awaitingReview>> = [];
  let sops: Awaited<ReturnType<typeof listSops>> = [];
  let error = "";
  try {
    [queue, sops] = await Promise.all([awaitingReview(), listSops()]);
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }
  return (
    <section id="brain">
      <h2>Shared Brain review</h2>
      <p className="muted">
        Candidates the user said yes to, already scrubbed (names, emails, phones, amounts, dates,
        addresses, ids replaced). Approve publishes a new version attributed to a source hash only.
      </p>
      {error && <p className="err" style={{ textAlign: "left" }}>Unavailable: {error}</p>}
      {queue.length === 0 && !error && <p className="muted">Nothing awaiting review.</p>}
      {queue.map((row) => {
        const c = (typeof row.candidate === "string" ? JSON.parse(row.candidate) : row.candidate) as Candidate;
        const scrubbed = Object.entries(c.scrubbed ?? {}).map(([k, n]) => `${n} ${k}`).join(", ");
        return (
          <div key={row.id} className="panel-card" style={{ marginTop: 16 }}>
            <h3 style={{ marginTop: 0 }}>{c.title} <span className="muted">({c.kind})</span></h3>
            <pre style={{ whiteSpace: "pre-wrap", fontFamily: "inherit" }}>{c.body}</pre>
            <p className="muted">
              {scrubbed ? `Scrubbed: ${scrubbed}. ` : "Nothing needed scrubbing. "}
              {c.reasons?.join("; ")} · consented {row.consent_at ? new Date(row.consent_at).toLocaleString() : "—"}
            </p>
            <form action={adminBrainApprove} style={{ display: "inline" }}>
              <input type="hidden" name="id" value={row.id} />
              <button>Approve &amp; publish</button>
            </form>{" "}
            <form action={adminBrainReject} style={{ display: "inline" }}>
              <input type="hidden" name="id" value={row.id} />
              <button className="linkish">Reject</button>
            </form>
          </div>
        );
      })}
      {sops.length > 0 && (
        <>
          <h3>Published</h3>
          <ul>
            {sops.map((s) => (
              <li key={s.id}>
                {s.title} — v{s.version} · {new Date(s.published_at).toLocaleDateString()} · source {s.source_user_hash.slice(0, 8)}…
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}
