import { redirect } from "next/navigation";
import { getSession } from "@/lib/auth";
import {
  accountKeyStatus,
  activationsFor,
  ensureSchema,
  getReseller,
  licencesForEmail,
  subLicencesOf,
  type LicenceRow,
  type Reseller,
} from "@/lib/db";
import { UNLIMITED } from "@/lib/stripe";
import {
  meterStatusFor,
  OVERAGE_CTRL_PER_HOUR,
  OVERAGE_DICT_PER_HOUR,
  TOPUP_BLOCKS,
  type MeterStatus,
} from "@/lib/metering";
import { Lockup } from "@/components/Logo";
import { TopUp } from "@/components/TopUp";
import {
  clearAccountKey,
  connectStripe,
  createSubLicence,
  freeSeat,
  newProvisionKey,
  removeSubUser,
  saveAccountKey,
  saveResellerPrice,
} from "./actions";

export const dynamic = "force-dynamic";

/** Member dashboard: your keys, the Macs using them, and reseller sub-users. */
export default async function Account({
  searchParams,
}: {
  searchParams: Promise<{ provkey?: string }>;
}) {
  const session = await getSession();
  if (!session) redirect("/login");
  const { provkey = "" } = await searchParams;

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
  const holderLicence = licences.find((l) => !l.parent_key);
  const isHolder = !!holderLicence;
  const isCloud = holderLicence?.mode === "cloud";

  // Cloud holders see usage + top-up instead of the BYOK key editor.
  let meter: MeterStatus | null = null;
  if (isCloud) {
    try {
      meter = await meterStatusFor(session.email);
    } catch (err) {
      console.error("account page could not read the meter", err);
    }
  }

  // Resellers (a resell plan holder) get Connect + provisioning tools.
  const isReseller = holderLicence?.resell ?? false;
  let reseller: Reseller | null = null;
  if (isReseller) {
    try {
      reseller = await getReseller(session.email);
    } catch (err) {
      console.error("account page could not read the reseller", err);
    }
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

      {isHolder && !isCloud && <AccountKeys status={keyStatus} />}
      {isCloud && meter?.metered && <CloudUsage meter={meter} />}
      {isReseller && <ResellerTools reseller={reseller} provkey={provkey} />}
    </div>
  );
}

/**
 * Reseller tools: connect their own Stripe to take payment, set the price they
 * charge (floored at our Solo price), and mint a provisioning API key for
 * creating sub-users programmatically.
 */
function ResellerTools({ reseller, provkey }: { reseller: Reseller | null; provkey: string }) {
  const connected = !!reseller?.connect_account_id;
  const price = ((reseller?.price_cents ?? 300) / 100).toFixed(2);
  const hasKey = !!reseller?.provision_key_hash;

  return (
    <section style={{ borderTop: 0, paddingTop: 8 }}>
      <h2>Reseller tools</h2>
      <div className="panel-card">
        {provkey && (
          <div style={{ marginBottom: 18 }}>
            <strong>Your new provisioning key</strong>
            <p className="dim small">Copy it now — it&rsquo;s shown only once.</p>
            <code className="keychip">{provkey}</code>
          </div>
        )}

        <div className="row-between">
          <div>
            <strong>Take payment</strong>
            <p className="dim small">
              {connected
                ? "Stripe connected — your customers pay you directly."
                : "Connect your own Stripe to bill your customers."}
            </p>
          </div>
          <form action={connectStripe}>
            <button className="btn btn-primary">
              {connected ? "Re-onboard" : "Connect Stripe"}
            </button>
          </form>
        </div>

        <hr className="rule" />

        <strong>Your price to customers</strong>
        <p className="dim small">
          At least $3.00/week — our Solo price. You keep the difference; give it away free
          or bundle it into a ≥ $15/month product.
        </p>
        <form action={saveResellerPrice} className="inline-form">
          <span>$</span>
          <input
            className="field"
            name="price"
            type="number"
            step="0.01"
            min={3}
            defaultValue={price}
            style={{ maxWidth: 120 }}
          />
          <span className="dim small">/ week</span>
          <button className="btn btn-ghost">Save</button>
        </form>

        <hr className="rule" />

        <strong>Provisioning API</strong>
        <p className="dim small">
          Create Solo sub-users programmatically for free/bundled distribution: POST{" "}
          <code>{`{ "email": "..." }`}</code> to <code>/api/reseller/provision</code> with your
          key as a <code>Bearer</code> token.
        </p>
        <form action={newProvisionKey}>
          <button className="btn btn-ghost">{hasKey ? "Regenerate key" : "Generate key"}</button>
        </form>
      </div>
    </section>
  );
}

/**
 * Cloud usage this week against the plan's included hours, the credit balance,
 * and top-up. Cloud runs on the platform's keys, so there's no key to set — this
 * replaces the BYOK key editor.
 */
function CloudUsage({ meter }: { meter: MeterStatus }) {
  return (
    <section style={{ borderTop: 0, paddingTop: 8 }}>
      <h2>Cloud usage this week</h2>
      <div className="panel-card">
        <dl className="facts">
          <div>
            <dt>Controller</dt>
            <dd>
              {meter.ctrlHours.toFixed(1)} / {meter.allowance.ctrl} hrs
            </dd>
          </div>
          <div>
            <dt>Dictation</dt>
            <dd>
              {meter.dictHours.toFixed(1)} / {meter.allowance.dict} hrs
            </dd>
          </div>
          <div>
            <dt>Credit</dt>
            <dd>${meter.creditDollars.toFixed(2)}</dd>
          </div>
        </dl>
        {meter.ok ? (
          meter.overageDue > 0 && (
            <p className="dim small">
              You&rsquo;re over your included hours — ${meter.overageDue.toFixed(2)} of overage
              this week, covered by your credit.
            </p>
          )
        ) : (
          <p className="err" style={{ textAlign: "left" }}>
            You&rsquo;re out of included hours and credit — the app is paused until the week
            resets or you top up.
          </p>
        )}
        <hr className="rule" />
        <p className="dim small">
          Beyond your weekly hours, usage draws from credit at ${OVERAGE_CTRL_PER_HOUR}/hr
          controller and ${OVERAGE_DICT_PER_HOUR}/hr dictation. Add credit:
        </p>
        <TopUp blocks={TOPUP_BLOCKS} />
      </div>
    </section>
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
            {devices.length} active <span className="dim">· unlimited</span>
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
                    <button className="linkish danger">Sign out</button>
                  </form>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p className="dim small">
        Use it on as many devices as you like. Signing a device out here removes it
        from the list; it keeps working until its current licence period ends.
      </p>

      {licence.sub_users > 0 && (
        <>
          <h4>Sub-users</h4>
          <p className="dim small">
            {licence.sub_users >= UNLIMITED
              ? `${subs.length} added. Each gets their own login and unlimited devices, expiring with your subscription.`
              : `${subs.length} of ${licence.sub_users} included. Each gets their own login and unlimited devices, expiring with your subscription.`}
          </p>

          {subs.length > 0 && (
            <table className="table">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Note</th>
                  <th>Devices</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {subs.map((s) => (
                  <tr key={s.key}>
                    <td>{s.email}</td>
                    <td>{s.note ?? "—"}</td>
                    <td>{s.devices}</td>
                    <td style={{ textAlign: "right" }}>
                      <form action={removeSubUser}>
                        <input type="hidden" name="key" value={licence.key} />
                        <input type="hidden" name="subKey" value={s.key} />
                        <button className="linkish danger">Remove</button>
                      </form>
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
