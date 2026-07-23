import { redirect } from "next/navigation";
import { getSession } from "@/lib/auth";
import { catalogue } from "@/lib/catalogue";
import { ensureSchema, licenceStats, searchLicences, type PlanRow } from "@/lib/db";
import { stripe } from "@/lib/stripe";
import { Lockup } from "@/components/Logo";
import {
  adminArchivePrice,
  adminCreatePrice,
  adminCreatePromo,
  adminDelete,
  adminDeletePlan,
  adminExtend,
  adminIssue,
  adminSavePlan,
  adminSetRevoked,
  adminSetSeats,
  adminTogglePromo,
} from "./actions";

export const dynamic = "force-dynamic";

/**
 * Admin dashboard. One page with sections rather than sub-routes: everything
 * here is low-traffic and occasional, and a single page means one load and no
 * navigation to get between "who bought what" and "why can't they buy it".
 */
export default async function Admin({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const session = await getSession();
  if (!session) redirect("/login");
  if (!session.admin) redirect("/account");

  const { q = "" } = await searchParams;

  // Report a database problem in place rather than 500-ing: the Stripe sections
  // below still work, and knowing *which* dependency is down is the first thing
  // you want during an incident.
  let stats = { total: 0, active: 0, revoked: 0, devices: 0 };
  let licences: Awaited<ReturnType<typeof searchLicences>> = [];
  let plans: PlanRow[] = [];
  let dbError = "";
  try {
    await ensureSchema();
    [stats, licences, plans] = await Promise.all([
      licenceStats(),
      searchLicences(q),
      catalogue(),
    ]);
  } catch (err) {
    dbError = err instanceof Error ? err.message : String(err);
    console.error("admin page could not read the database", err);
  }

  // Stripe may be unconfigured or down; the licence half of this page is the
  // half that matters in an incident, so never let Stripe take it down with it.
  let promos: any[] = [];
  let stripeError = "";
  try {
    promos = (await stripe().promotionCodes.list({ limit: 50 })).data;
  } catch (err) {
    stripeError = err instanceof Error ? err.message : String(err);
  }

  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        <a href="#licences">Licences</a>
        <a href="#orderform">Order form</a>
        <a href="#promos">Promo codes</a>
        <a href="/account">My account</a>
        <form action="/api/auth/logout" method="post" style={{ display: "inline" }}>
          <button className="linkish">Sign out</button>
        </form>
      </nav>

      <section style={{ borderTop: 0, paddingTop: 40, paddingBottom: 40 }}>
        <h2>Admin</h2>
        {dbError && (
          <p className="err" style={{ textAlign: "left" }}>
            Database unavailable — licences and the order form can&rsquo;t be read or
            edited. {dbError}
          </p>
        )}
        <div className="stats">
          <Stat label="Licences" value={stats.total} />
          <Stat label="Active" value={stats.active} />
          <Stat label="Revoked" value={stats.revoked} />
          <Stat label="Devices" value={stats.devices} />
        </div>
      </section>

      {/* ---------------- licences ---------------- */}
      <section id="licences">
        <h2>Licences</h2>

        <form method="get" className="inline-form">
          <input className="field" name="q" defaultValue={q}
                 placeholder="Search email, key or plan…" />
          <button className="btn btn-ghost">Search</button>
        </form>

        {licences.length === 0 ? (
          <p className="dim">No licences match.</p>
        ) : (
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Key</th>
                  <th>Email</th>
                  <th>Plan</th>
                  <th>Seats</th>
                  <th>Expires</th>
                  <th>State</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {licences.map((l) => (
                  <tr key={l.key}>
                    <td>
                      <code>{l.key}</code>
                      {l.parent_key && <div className="dim small">sub-user</div>}
                    </td>
                    <td>{l.email}</td>
                    <td>{l.plan}</td>
                    <td>
                      <form action={adminSetSeats} className="tight">
                        <input type="hidden" name="key" value={l.key} />
                        <input className="field mini" name="seats" type="number"
                               min={0} defaultValue={l.seats} />
                        <span className="dim small">{l.devices} used</span>
                      </form>
                    </td>
                    <td>
                      {l.expires_at ? l.expires_at.toLocaleDateString() : "never"}
                      <form action={adminExtend} className="tight">
                        <input type="hidden" name="key" value={l.key} />
                        <input className="field mini" name="days" type="number"
                               defaultValue={7} />
                        <button className="linkish">+days</button>
                      </form>
                    </td>
                    <td>
                      {l.revoked ? (
                        <span className="pill bad">Revoked</span>
                      ) : (
                        <span className="pill good">OK</span>
                      )}
                    </td>
                    <td className="actions">
                      <form action={adminSetRevoked}>
                        <input type="hidden" name="key" value={l.key} />
                        <input type="hidden" name="revoked" value={l.revoked ? "0" : "1"} />
                        <button className="linkish">{l.revoked ? "Restore" : "Revoke"}</button>
                      </form>
                      <form action={adminDelete}>
                        <input type="hidden" name="key" value={l.key} />
                        <button className="linkish danger">Delete</button>
                      </form>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <h3 style={{ marginTop: 36 }}>Issue a licence by hand</h3>
        <p className="dim small">
          For comps and replacements. This creates no Stripe subscription, so
          nothing bills and nothing renews — set an expiry of 0 for a permanent key.
        </p>
        <form action={adminIssue} className="form-grid">
          <label>Email<input className="field" name="email" type="email" required /></label>
          <label>Plan<input className="field" name="plan" defaultValue="solo" /></label>
          <label>Computers<input className="field" name="seats" type="number" defaultValue={2} /></label>
          <label>Phones<input className="field" name="phones" type="number" defaultValue={1} /></label>
          <label>Sub-users<input className="field" name="subUsers" type="number" defaultValue={0} /></label>
          <label>Days (0 = never expires)<input className="field" name="days" type="number" defaultValue={0} /></label>
          <label>Note<input className="field" name="note" placeholder="why this was issued" /></label>
          <label className="check"><input type="checkbox" name="resell" /> Resell rights</label>
          <button className="btn btn-primary">Issue licence</button>
        </form>
      </section>

      {/* ---------------- order form ---------------- */}
      <section id="orderform">
        <h2>Order form</h2>
        <p className="sub">
          These rows are the pricing page. Editing one changes what customers see
          immediately — no deploy. Entitlements here are what a new purchase grants.
        </p>

        {plans.map((p) => (
          <PlanEditor key={p.slug} plan={p} />
        ))}

        <details style={{ marginTop: 28 }}>
          <summary>Add a plan</summary>
          <PlanEditor plan={blankPlan(plans.length)} isNew />
        </details>

        <h3 style={{ marginTop: 40 }}>Create a Stripe product &amp; price</h3>
        <p className="dim small">
          Creates the product and a recurring price, then points that plan at it.
          Stripe prices are immutable — changing a price always means a new one,
          and existing subscribers stay on the price they signed up at.
        </p>
        <form action={adminCreatePrice} className="form-grid">
          <label>Plan slug<input className="field" name="slug" required placeholder="solo" /></label>
          <label>Product name<input className="field" name="name"
                 placeholder="Look Ma No Hands App - Solo" /></label>
          <label>Amount (USD)<input className="field" name="amount" type="number"
                 step="0.01" required placeholder="3" /></label>
          <label>
            Billing period
            <select className="field" name="interval" defaultValue="week">
              <option value="day">daily</option>
              <option value="week">weekly</option>
              <option value="month">monthly</option>
              <option value="year">yearly</option>
            </select>
          </label>
          <label>Description<input className="field" name="description" /></label>
          <button className="btn btn-primary">Create in Stripe</button>
        </form>
      </section>

      {/* ---------------- promo codes ---------------- */}
      <section id="promos">
        <h2>Promo codes</h2>
        {stripeError ? (
          <p className="err">Stripe unavailable: {stripeError}</p>
        ) : promos.length === 0 ? (
          <p className="dim">No promotion codes yet.</p>
        ) : (
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Code</th>
                  <th>Discount</th>
                  <th>Duration</th>
                  <th>Used</th>
                  <th>State</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {promos.map((p) => (
                  <tr key={p.id}>
                    <td><code>{p.code}</code></td>
                    <td>
                      {p.coupon?.percent_off
                        ? `${p.coupon.percent_off}%`
                        : p.coupon?.amount_off
                          ? `$${(p.coupon.amount_off / 100).toFixed(2)}`
                          : "—"}
                    </td>
                    <td>
                      {p.coupon?.duration === "repeating"
                        ? `${p.coupon.duration_in_months} months`
                        : p.coupon?.duration ?? "—"}
                    </td>
                    <td>
                      {p.times_redeemed}
                      {p.max_redemptions ? ` / ${p.max_redemptions}` : ""}
                    </td>
                    <td>
                      {p.active ? (
                        <span className="pill good">Active</span>
                      ) : (
                        <span className="pill bad">Off</span>
                      )}
                    </td>
                    <td>
                      <form action={adminTogglePromo}>
                        <input type="hidden" name="id" value={p.id} />
                        <input type="hidden" name="active" value={p.active ? "0" : "1"} />
                        <button className="linkish">{p.active ? "Disable" : "Enable"}</button>
                      </form>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <h3 style={{ marginTop: 32 }}>Create a code</h3>
        <form action={adminCreatePromo} className="form-grid">
          <label>Code<input className="field" name="code" required placeholder="LAUNCH50" /></label>
          <label>Percent off<input className="field" name="percent" type="number"
                 min={0} max={100} placeholder="50" /></label>
          <label>…or amount off (USD)<input className="field" name="amount"
                 type="number" step="0.01" placeholder="1.50" /></label>
          <label>Billing periods (1 = first only, 0 = forever)
            <input className="field" name="months" type="number" defaultValue={1} /></label>
          <label>Max redemptions (0 = unlimited)
            <input className="field" name="max" type="number" defaultValue={0} /></label>
          <button className="btn btn-primary">Create code</button>
        </form>
        <p className="dim small">
          Checkout already accepts promotion codes, so a code created here works
          immediately on the pricing page.
        </p>
      </section>
    </div>
  );
}

function blankPlan(count: number): PlanRow {
  return {
    slug: "", name: "", tagline: "", price_id: null, price_label: "", period: "/ week",
    features: [], computers: 2, phones: 0, sub_users: 0, resell: false,
    featured: false, visible: true, sort: (count + 1) * 10,
  };
}

function PlanEditor({ plan, isNew = false }: { plan: PlanRow; isNew?: boolean }) {
  return (
    <div className="panel-card">
      <form action={adminSavePlan} className="form-grid">
        <label>Slug
          <input className="field" name="slug" defaultValue={plan.slug}
                 readOnly={!isNew} required /></label>
        <label>Name<input className="field" name="name" defaultValue={plan.name} /></label>
        <label>Tagline<input className="field" name="tagline" defaultValue={plan.tagline} /></label>
        <label>Price label<input className="field" name="price_label"
               defaultValue={plan.price_label} placeholder="$3" /></label>
        <label>Period<input className="field" name="period" defaultValue={plan.period} /></label>
        <label>Stripe price id<input className="field" name="price_id"
               defaultValue={plan.price_id ?? ""} placeholder="price_…" /></label>
        <label>Computers<input className="field" name="computers" type="number"
               defaultValue={plan.computers} /></label>
        <label>Phones<input className="field" name="phones" type="number"
               defaultValue={plan.phones} /></label>
        <label>Sub-users<input className="field" name="sub_users" type="number"
               defaultValue={plan.sub_users} /></label>
        <label>Sort<input className="field" name="sort" type="number" defaultValue={plan.sort} /></label>
        <label className="wide">Features (one per line)
          <textarea className="field" name="features" rows={4}
                    defaultValue={plan.features.join("\n")} /></label>
        <label className="check">
          <input type="checkbox" name="visible" defaultChecked={plan.visible} /> Visible
        </label>
        <label className="check">
          <input type="checkbox" name="featured" defaultChecked={plan.featured} /> Featured
        </label>
        <label className="check">
          <input type="checkbox" name="resell" defaultChecked={plan.resell} /> Resell rights
        </label>
        <button className="btn btn-primary">{isNew ? "Add plan" : "Save"}</button>
      </form>

      {!isNew && (
        <div className="row-between" style={{ marginTop: 12 }}>
          <span className="dim small">
            {plan.price_id ? <code>{plan.price_id}</code> : "no Stripe price — not sellable"}
          </span>
          <span className="actions">
            {plan.price_id && (
              <form action={adminArchivePrice}>
                <input type="hidden" name="price_id" value={plan.price_id} />
                <button className="linkish">Archive price in Stripe</button>
              </form>
            )}
            <form action={adminDeletePlan}>
              <input type="hidden" name="slug" value={plan.slug} />
              <button className="linkish danger">Remove plan</button>
            </form>
          </span>
        </div>
      )}
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
