import { redirect } from "next/navigation";
import { getSession } from "@/lib/auth";
import {
  accountKeyStatus,
  activationsFor,
  ensureSchema,
  licencesForEmail,
  subLicencesOf,
  type LicenceRow,
} from "@/lib/db";
import { UNLIMITED } from "@/lib/stripe";
import { Lockup } from "@/components/Logo";
import { clearAccountKey, createSubLicence, freeSeat, saveAccountKey } from "./actions";

export const dynamic = "force-dynamic";

/** Member dashboard: your keys, the Macs using them, and reseller sub-users. */
export default async function Account() {
  const session = await getSession();
  if (!session) redirect("/login");

  // A database that's missing or down should say so plainly rather than throw a
  // stack trace at a paying customer.
  let licences: LicenceRow[] = [];
  let keyStatus = { anthropic: false, elevenlabs: false };
  let dbError = "";
  try {
    await ensureSchema();
    licences = await licencesForEmail(session.email);
    keyStatus = await accountKeyStatus(session.email);
  } catch (err) {
    dbError = err instanceof Error ? err.message : String(err);
    console.error("account page could not read licences", err);
  }

  // Anyone with a plan of their own (not purely a sub-user) sets the shared keys.
  const isHolder = licences.some((l) => !l.parent_key);

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

      {isHolder && <AccountKeys status={keyStatus} />}
    </div>
  );
}

/**
 * The account's shared Anthropic + ElevenLabs keys. Set once here; every Mac the
 * holder and their sub-users sign in on fetches them from the server — nobody
 * pastes a key into the app anymore. We only ever show whether a key is set, not
 * the key itself, so a shoulder-surfer or a stale screenshot leaks nothing.
 */
function AccountKeys({ status }: { status: { anthropic: boolean; elevenlabs: boolean } }) {
  return (
    <section style={{ borderTop: 0, paddingTop: 8 }}>
      <h2>App keys</h2>
      <p className="dim">
        Set your Anthropic and ElevenLabs keys once. Every device you and your
        sub-users sign in on uses them automatically — there&rsquo;s nothing to paste
        into the app.
      </p>
      <div className="panel-card">
        <KeyField
          which="anthropic"
          label="Anthropic API key"
          placeholder="sk-ant-…"
          isSet={status.anthropic}
        />
        <hr className="rule" />
        <KeyField
          which="elevenlabs"
          label="ElevenLabs API key"
          placeholder="ElevenLabs API key"
          isSet={status.elevenlabs}
        />
      </div>
    </section>
  );
}

function KeyField({
  which,
  label,
  placeholder,
  isSet,
}: {
  which: "anthropic" | "elevenlabs";
  label: string;
  placeholder: string;
  isSet: boolean;
}) {
  return (
    <div style={{ display: "grid", gap: 10 }}>
      <div className="row-between">
        <strong>{label}</strong>
        {isSet ? (
          <span className="pill good">Set</span>
        ) : (
          <span className="pill warn">Not set</span>
        )}
      </div>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        <form action={saveAccountKey} className="inline-form" style={{ flex: 1 }}>
          <input type="hidden" name="which" value={which} />
          <input
            className="field"
            name="value"
            type="password"
            required
            autoComplete="off"
            placeholder={isSet ? "Enter a new key to replace it" : placeholder}
            style={{ flex: 1, minWidth: 220 }}
          />
          <button className="btn btn-primary">{isSet ? "Replace" : "Save"}</button>
        </form>
        {isSet && (
          <form action={clearAccountKey}>
            <input type="hidden" name="which" value={which} />
            <button className="linkish danger">Remove</button>
          </form>
        )}
      </div>
    </div>
  );
}

async function LicenceCard({ licence }: { licence: LicenceRow }) {
  const devices = await activationsFor(licence.key);
  const subs = licence.sub_users > 0 ? await subLicencesOf(licence.key) : [];
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
          <dt>Devices</dt>
          <dd>
            {devices.length} of {unlimited ? "unlimited" : licence.seats} in use
          </dd>
        </div>
        <div>
          <dt>Sub-users</dt>
          <dd>
            {licence.sub_users >= UNLIMITED
              ? "Unlimited"
              : licence.sub_users > 0
                ? `${subs.length} of ${licence.sub_users}`
                : "—"}
          </dd>
        </div>
        <div>
          <dt>{expired ? "Expired" : "Renews"}</dt>
          <dd>{licence.expires_at ? licence.expires_at.toLocaleDateString() : "Never"}</dd>
        </div>
      </dl>

      <h4>Signed-in devices</h4>
      {devices.length === 0 ? (
        <p className="dim">
          None yet. Open the app, click the menu-bar icon and choose{" "}
          <strong>Sign in</strong>.
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

      {licence.sub_users > 0 && (
        <>
          <h4>Sub-users</h4>
          <p className="dim small">
            {licence.sub_users >= UNLIMITED
              ? `${subs.length} added. Each gets their own login and 3 devices, expiring with your subscription.`
              : `${subs.length} of ${licence.sub_users} included. Each gets their own login and 3 devices, expiring with your subscription.`}
          </p>

          {subs.length > 0 && (
            <table className="table">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Note</th>
                  <th>Devices</th>
                </tr>
              </thead>
              <tbody>
                {subs.map((s) => (
                  <tr key={s.key}>
                    <td>{s.email}</td>
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
              <button className="btn btn-primary">Add sub-user</button>
            </form>
          ) : (
            <p className="dim small">
              You&rsquo;ve added all {licence.sub_users} sub-users on your plan. Upgrade
              to Community for unlimited sub-users.
            </p>
          )}
          <p className="dim small">
            Sub-users sign in with their own email — they never need a key. Add the
            email here, then tell them to sign in on the app.
          </p>
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
