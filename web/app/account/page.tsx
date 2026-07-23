import { redirect } from "next/navigation";
import { getSession } from "@/lib/auth";
import {
  activationsFor,
  ensureSchema,
  licencesForEmail,
  subLicencesOf,
  type LicenceRow,
} from "@/lib/db";
import { UNLIMITED } from "@/lib/stripe";
import { Lockup } from "@/components/Logo";
import { createSubLicence, freeSeat } from "./actions";

export const dynamic = "force-dynamic";

/** Member dashboard: your keys, the Macs using them, and reseller sub-users. */
export default async function Account() {
  const session = await getSession();
  if (!session) redirect("/login");

  // A database that's missing or down should say so plainly rather than throw a
  // stack trace at a paying customer.
  let licences: LicenceRow[] = [];
  let dbError = "";
  try {
    await ensureSchema();
    licences = await licencesForEmail(session.email);
  } catch (err) {
    dbError = err instanceof Error ? err.message : String(err);
    console.error("account page could not read licences", err);
  }

  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        {session.admin && <a href="/admin">Admin</a>}
        <span style={{ fontSize: 13, color: "var(--muted)" }}>{session.email}</span>
        <form action="/api/auth/logout" method="post" style={{ display: "inline" }}>
          <button className="linkish">Sign out</button>
        </form>
      </nav>

      <section style={{ borderTop: 0, paddingTop: 48 }}>
        <h2>Your subscription</h2>

        {dbError ? (
          <div className="card" style={{ marginTop: 24 }}>
            <h3>Can&rsquo;t reach the licence database</h3>
            <p>
              Your subscription is safe — this is our problem, not yours. Try again
              shortly, or email support@nohandsapp.com if it persists.
            </p>
          </div>
        ) : licences.length === 0 ? (
          <div className="card" style={{ marginTop: 24 }}>
            <h3>Nothing here yet</h3>
            <p>
              No licence is registered to {session.email}. If you subscribed with a
              different address, sign in with that one instead — or{" "}
              <a href="/#pricing">choose a plan</a>.
            </p>
          </div>
        ) : (
          licences.map((l) => <LicenceCard key={l.key} licence={l} />)
        )}
      </section>
    </div>
  );
}

async function LicenceCard({ licence }: { licence: LicenceRow }) {
  const devices = await activationsFor(licence.key);
  const subs = licence.resell ? await subLicencesOf(licence.key) : [];
  const unlimited = licence.seats >= UNLIMITED;
  const expired = licence.expires_at ? licence.expires_at.getTime() < Date.now() : false;

  return (
    <div className="panel-card">
      <div className="row-between">
        <div>
          <h3 style={{ margin: 0, textTransform: "capitalize" }}>{licence.plan}</h3>
          <code className="keychip">{licence.key}</code>
        </div>
        <Status licence={licence} expired={expired} />
      </div>

      <dl className="facts">
        <div>
          <dt>Computers</dt>
          <dd>
            {devices.length} of {unlimited ? "unlimited" : licence.seats} in use
          </dd>
        </div>
        <div>
          <dt>Phones</dt>
          <dd>{licence.phones >= UNLIMITED ? "Unlimited" : licence.phones}</dd>
        </div>
        <div>
          <dt>{expired ? "Expired" : "Renews"}</dt>
          <dd>{licence.expires_at ? licence.expires_at.toLocaleDateString() : "Never"}</dd>
        </div>
      </dl>

      <h4>Activated computers</h4>
      {devices.length === 0 ? (
        <p className="dim">
          None yet. Open the app, click the menu-bar icon and paste your key.
        </p>
      ) : (
        <table className="table">
          <thead>
            <tr>
              <th>Machine</th>
              <th>App</th>
              <th>Last seen</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {devices.map((d) => (
              <tr key={d.device}>
                <td>
                  <code>{d.device.slice(0, 12)}…</code>
                </td>
                <td>{d.app_version ?? "—"}</td>
                <td>{d.last_seen.toLocaleDateString()}</td>
                <td style={{ textAlign: "right" }}>
                  <form action={freeSeat}>
                    <input type="hidden" name="key" value={licence.key} />
                    <input type="hidden" name="device" value={d.device} />
                    <button className="linkish danger">Free this seat</button>
                  </form>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p className="dim small">
        Freeing a seat lets you activate another Mac. The old one keeps working until
        its current licence period ends, then stops renewing.
      </p>

      {licence.resell && (
        <>
          <h4>Sub-users</h4>
          <p className="dim small">
            {subs.length} of {licence.sub_users} included. Each one gets a Solo key
            (2 computers, 1 phone) that expires with your own subscription.
          </p>

          {subs.length > 0 && (
            <table className="table">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Key</th>
                  <th>Note</th>
                  <th>Computers</th>
                </tr>
              </thead>
              <tbody>
                {subs.map((s) => (
                  <tr key={s.key}>
                    <td>{s.email}</td>
                    <td>
                      <code>{s.key}</code>
                    </td>
                    <td>{s.note ?? "—"}</td>
                    <td>
                      {s.devices} / {s.seats}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}

          {subs.length < licence.sub_users ? (
            <form action={createSubLicence} className="inline-form">
              <input type="hidden" name="key" value={licence.key} />
              <input className="field" name="email" type="email" required
                     placeholder="sub-user@example.com" />
              <input className="field" name="note" placeholder="Note (optional)" />
              <button className="btn btn-primary">Create key</button>
            </form>
          ) : (
            <p className="dim small">
              All {licence.sub_users} included sub-users issued. Additional users are
              $1/week — email support@nohandsapp.com to raise your allowance.
            </p>
          )}
        </>
      )}
    </div>
  );
}

function Status({ licence, expired }: { licence: LicenceRow; expired: boolean }) {
  if (licence.revoked) return <span className="pill bad">Revoked</span>;
  if (expired) return <span className="pill warn">Lapsed</span>;
  return <span className="pill good">Active</span>;
}
