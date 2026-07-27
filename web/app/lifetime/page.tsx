import { countLifetimeLicences, ensureSchema } from "@/lib/db";
import { FOUNDER_CAP, LIFETIME_TIERS, lifetimePrice } from "@/lib/lifetime";
import { Lockup } from "@/components/Logo";
import { LifetimeBuy } from "@/components/LifetimeBuy";

export const dynamic = "force-dynamic";

const money = (n: number) => `$${n.toLocaleString("en-US")}`;

export default async function Lifetime() {
  let sold = 0;
  try {
    await ensureSchema();
    sold = await countLifetimeLicences();
  } catch (err) {
    console.error("lifetime page could not read the sold count", err);
  }
  const remaining = Math.max(0, FOUNDER_CAP - sold);
  const founderOn = sold < FOUNDER_CAP;

  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        <a href="/#pricing">Weekly plans</a>
        <a href="/account">Sign in</a>
      </nav>

      <section style={{ borderTop: 0, paddingTop: 56 }}>
        <h1 style={{ textAlign: "center" }}>Pay once. Yours for life.</h1>
        <p className="sub" style={{ textAlign: "center", maxWidth: "44ch", margin: "0 auto" }}>
          Lifetime access on your own Anthropic + ElevenLabs keys — no subscription, no
          renewal, unlimited devices.
        </p>
        <p
          className={founderOn ? "" : "dim"}
          style={{ textAlign: "center", marginTop: 14, fontWeight: 600 }}
        >
          {founderOn
            ? `Founder pricing — ${remaining} of ${FOUNDER_CAP} spots left. Prices rise once they're gone.`
            : "Founder pricing has sold out — standard lifetime pricing below."}
        </p>

        <div className="prices" style={{ marginTop: 28 }}>
          {LIFETIME_TIERS.map((t) => {
            const price = lifetimePrice(t, sold);
            const onFounder = price === t.founder && founderOn;
            return (
              <div key={t.key} className={`price${t.featured ? " featured" : ""}`}>
                <span className="tag">
                  {t.name}
                  {t.tagline ? ` · ${t.tagline}` : ""}
                </span>
                <div className="amount">
                  {money(price)} <span>one-time</span>
                </div>
                {onFounder && (
                  <p className="dim small">
                    Founder price — rises to {money(t.standard)} after {FOUNDER_CAP} sold
                  </p>
                )}
                <ul>
                  {t.features.map((f, i) => (
                    <li key={i}>{f}</li>
                  ))}
                </ul>
                <LifetimeBuy tier={t.key} featured={t.featured} label={`Get ${t.name}`} />
              </div>
            );
          })}
        </div>

        <p className="footnote" style={{ textAlign: "center", marginTop: 24 }}>
          Lifetime is bring-your-own-key only — you run on your own AI keys, so there&rsquo;s
          nothing metered and nothing to renew. Prefer we run the AI? See the{" "}
          <a href="/#pricing">weekly Cloud plans</a>.
        </p>
      </section>
    </div>
  );
}
