import { betaEnabled, listBetaRedemptions } from "@/lib/db-beta";
import { adminToggleBeta } from "./beta-actions";

/** /admin › Beta: the programme switch and every redemption. */
export default async function BetaAdmin() {
  let on = true;
  let rows: Awaited<ReturnType<typeof listBetaRedemptions>> = [];
  let error = "";
  try {
    on = await betaEnabled();
    rows = await listBetaRedemptions();
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  }
  const money = (c: number) => `$${(c / 100).toFixed(0)}`;
  return (
    <section id="beta">
      <h2>Beta ($99 for life)</h2>
      <p className="dim">
        Secret page at <code>/beta</code> (not linked, not indexed). Codes are <code>BETA##</code> —
        the number is dollars off, up to 99. <code>BETA99</code> is a free seat and needs a sign-in.
      </p>
      <form action={adminToggleBeta} style={{ marginBottom: 16 }}>
        <input type="hidden" name="on" value={on ? "0" : "1"} />
        <span className={on ? "pill good" : "pill bad"}>{on ? "Open" : "Closed"}</span>{" "}
        <button className="linkish">{on ? "Close the beta" : "Reopen the beta"}</button>
      </form>
      {error ? (
        <p className="err">{error}</p>
      ) : rows.length === 0 ? (
        <p className="dim">No redemptions yet.</p>
      ) : (
        <div className="scroll-x">
          <table className="table">
            <thead>
              <tr><th>When</th><th>Email</th><th>Code</th><th>Off</th><th>Paid</th><th>Licence</th></tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>{new Date(r.created_at).toLocaleString("en-US")}</td>
                  <td>{r.email}</td>
                  <td><code>{r.code ?? "—"}</code></td>
                  <td>{money(r.discount_cents)}</td>
                  <td>{money(r.paid_cents)}</td>
                  <td><code>{r.licence_key.slice(0, 8)}…</code></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
