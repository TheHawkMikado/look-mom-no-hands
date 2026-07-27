import { notFound } from "next/navigation";
import { countLifetimeLicences, ensureSchema } from "@/lib/db";
import { lifetimePrice, lifetimeTier, RESELLER_UPGRADE_PRICE, upsellBySlug } from "@/lib/lifetime";
import { Lockup } from "@/components/Logo";
import { LifetimeBuy } from "@/components/LifetimeBuy";

export const dynamic = "force-dynamic";

const money = (n: number) => `$${n.toLocaleString("en-US")}`;

export default async function UpsellPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const upsell = upsellBySlug(slug);
  if (!upsell) notFound();
  const tier = lifetimeTier(upsell.tier)!;

  let sold = 0;
  try {
    await ensureSchema();
    sold = await countLifetimeLicences();
  } catch (err) {
    console.error("upsell page could not read the sold count", err);
  }
  const price = upsell.upgrade ? RESELLER_UPGRADE_PRICE : lifetimePrice(tier, sold);

  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        <a href="/lifetime">All lifetime plans</a>
        <a href="/account">Sign in</a>
      </nav>

      <section style={{ borderTop: 0, paddingTop: 56, textAlign: "center" }}>
        <p className="dim" style={{ textTransform: "uppercase", letterSpacing: ".1em", fontSize: 12 }}>
          For {upsell.from} members
        </p>
        <h1 style={{ marginTop: 8 }}>{upsell.headline}</h1>
        <p className="sub" style={{ maxWidth: "48ch", margin: "12px auto 0" }}>
          {upsell.pitch}
        </p>

        <div className="prices" style={{ marginTop: 30, justifyContent: "center" }}>
          <div className="price featured" style={{ maxWidth: 380 }}>
            <span className="tag">
              {tier.name}
              {upsell.upgrade ? " · upgrade" : ""}
            </span>
            <div className="amount">
              {money(price)} <span>one-time</span>
            </div>
            <ul>
              {tier.features.map((f, i) => (
                <li key={i}>{f}</li>
              ))}
            </ul>
            <LifetimeBuy
              tier={tier.key}
              upgrade={upsell.upgrade}
              featured
              label={upsell.upgrade ? `Upgrade for ${money(price)}` : `Get ${tier.name} — ${money(price)}`}
            />
          </div>
        </div>

        <p className="footnote" style={{ marginTop: 20 }}>
          One-time payment, yours for life, on your own keys.{" "}
          <a href="/lifetime">Compare all lifetime plans</a>.
        </p>
      </section>
    </div>
  );
}
