import { BETA_TESTER_SEATS, countAcceptedTesters, listApplications, listFeedback } from "@/lib/db-beta";
import { adminAcceptTester, adminDeclineTester } from "./beta-actions";

/** /admin › Beta testers: applications (accept mints + emails the free seat) and the monthly forms. */
export default async function TestersAdmin() {
  let apps: Awaited<ReturnType<typeof listApplications>> = [];
  let forms: Awaited<ReturnType<typeof listFeedback>> = [];
  let taken = 0;
  let error = "";
  try {
    [apps, forms, taken] = await Promise.all([listApplications(), listFeedback(), countAcceptedTesters()]);
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  }
  const when = (d: Date) => new Date(d).toLocaleDateString("en-US");
  return (
    <section id="testers">
      <h2>Beta testers ({taken}/{BETA_TESTER_SEATS} seats)</h2>
      <p className="dim">
        Applications from <code>/testers</code>. Accept mints a free lifetime <code>beta</code> licence and emails
        it with the install steps and the feedback-form link (<code>/testers/feedback</code>).
      </p>
      {error ? <p className="err">{error}</p> : null}
      {apps.length === 0 ? (
        <p className="dim">No applications yet.</p>
      ) : (
        <div className="scroll-x">
          <table className="table">
            <thead>
              <tr><th>When</th><th>Who</th><th>Does</th><th>Mac</th><th>Would hand it</th><th>Status</th><th></th></tr>
            </thead>
            <tbody>
              {apps.map((a) => (
                <tr key={a.id}>
                  <td>{when(a.created_at)}</td>
                  <td>{a.name}<br /><span className="dim small">{a.email}</span>{a.social ? <><br /><span className="dim small">{a.social}</span></> : null}</td>
                  <td>{a.role}</td>
                  <td>{a.machine}</td>
                  <td style={{ maxWidth: 320, whiteSpace: "pre-wrap" }}>{a.use_case}</td>
                  <td><span className={`pill ${a.status === "accepted" ? "good" : a.status === "declined" ? "bad" : ""}`}>{a.status}</span></td>
                  <td>
                    {a.status === "pending" ? (
                      <span style={{ display: "inline-flex", gap: 8 }}>
                        <form action={adminAcceptTester}><input type="hidden" name="id" value={a.id} /><button className="linkish">Accept</button></form>
                        <form action={adminDeclineTester}><input type="hidden" name="id" value={a.id} /><button className="linkish">Decline</button></form>
                      </span>
                    ) : a.licence_key ? <code>{a.licence_key.slice(0, 8)}…</code> : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <h3 style={{ marginTop: 24 }}>Monthly feedback</h3>
      {forms.length === 0 ? (
        <p className="dim">No forms yet.</p>
      ) : (
        <div className="scroll-x">
          <table className="table">
            <thead>
              <tr><th>Month</th><th>Who</th><th>Hours</th><th>Score</th><th>Worked</th><th>Broke</th><th>Wish</th></tr>
            </thead>
            <tbody>
              {forms.map((f) => (
                <tr key={f.id}>
                  <td>{f.month}</td>
                  <td>{f.email}</td>
                  <td>{f.hours}</td>
                  <td>{f.score}/10</td>
                  <td style={{ maxWidth: 260, whiteSpace: "pre-wrap" }}>{f.worked}</td>
                  <td style={{ maxWidth: 260, whiteSpace: "pre-wrap" }}>{f.broke}</td>
                  <td style={{ maxWidth: 220, whiteSpace: "pre-wrap" }}>{f.wish}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
