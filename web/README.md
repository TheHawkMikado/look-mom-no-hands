# nohandsapp.com

Marketing site, Stripe checkout, and the licence service for **Look Ma, No Hands**.
Next.js App Router, deployed on Vercel.

## How a purchase flows

```
  Buyer clicks Buy
        │
        ▼
  POST /api/checkout ──────► Stripe Checkout (hosted, PCI is theirs)
        │                          │
        │                          ▼  payment succeeds
        │              POST /api/stripe/webhook   ← the ONLY place a licence is created
        │                          │
        │                          ├─ mint NOHANDS-XXXX-XXXX-XXXX
        │                          ├─ INSERT into licences
        │                          └─ email it (Resend)
        ▼
  /success?session_id=…  polls the DB and shows the key
        │
        ▼
  App: paste key ──► POST /api/activate ──► Ed25519-signed token, bound to that Mac
                                                    │
                                                    ▼
                              verified offline forever by the Swift app
```

The webhook — not the success page — issues licences. The success redirect is
something any browser can visit; only the webhook carries a Stripe signature.

## Setup

### 1. Licence signing keypair

```sh
../Scripts/gen_license_keypair.sh
```

Paste the **public** half into `LicenseConfig.publicKeyHex` in
`Sources/LookMomNoHands/LicenseStore.swift`, and set the **private** half as
`LICENSE_SIGNING_KEY` in Vercel. Put the private key in your password manager
too — losing it means every future activation fails.

> The app refuses to activate while `publicKeyHex` is still the all-zero
> placeholder, and `LicenseTests.testPlaceholderPublicKeyIsRecognisedAsUnconfigured`
> fails once you set it — delete that assertion then. It exists so a paid build
> can't ship with a dud key.

### 2. Database

Any Postgres reachable over SSL (Neon, Supabase, RDS). Set `DATABASE_URL`.
No migration step: `ensureSchema()` creates the tables on first request.

### 3. Stripe

1. Create three **Prices** in the dashboard and copy the `price_…` ids into
   `STRIPE_PRICE_PERSONAL`, `STRIPE_PRICE_PRO`, `STRIPE_PRICE_YEARLY`.
   The plan → seats/duration mapping lives in `lib/stripe.ts`, server-side, so
   the browser can never ask for terms it didn't pay for.
2. Add a webhook endpoint pointing at `https://nohandsapp.com/api/stripe/webhook`,
   subscribed to `checkout.session.completed` and `customer.subscription.deleted`.
   Copy its signing secret into `STRIPE_WEBHOOK_SECRET`.
3. Turn on **Stripe Tax** if you want VAT/sales tax calculated (`automatic_tax`
   is already enabled in the checkout call).

### 4. Vercel

Import the repo and set **Root Directory** to `web` — the Swift app lives in the
same repo and Vercel should not try to build it. Add every variable from
`.env.example`, then point `nohandsapp.com` at the project in Vercel's Domains
tab and update your registrar's nameservers or A/CNAME records as instructed.

### 5. Download hosting

`NEXT_PUBLIC_DOWNLOAD_URL` should point at the notarised DMG. GitHub Releases
is the simplest host — attach `build/LookMaNoHands-<version>.dmg` to a tagged
release and link to `/releases/latest`.

## Local development

```sh
cp .env.example .env.local     # fill in test-mode Stripe keys
npm install
npm run dev
```

Webhooks can't reach localhost, so forward them:

```sh
stripe listen --forward-to localhost:3000/api/stripe/webhook
```

That prints a `whsec_…` — use it as `STRIPE_WEBHOOK_SECRET` locally. Then run a
purchase with card `4242 4242 4242 4242`, any future expiry.

## Sales tax — the part that bites

Stripe Tax calculates tax; it does not register or remit for you. Selling
software worldwide means you may owe registration in the EU (VAT/OSS), the UK,
and various US states once you pass their thresholds. Two ways out:

- Keep Stripe and add a filing service, or engage an accountant once revenue
  justifies it.
- Or switch to a merchant of record (Paddle, Lemon Squeezy), which takes a
  larger cut and assumes the tax liability entirely.

Starting on Stripe and moving later is normal — thresholds are high enough that
early sales rarely trigger anything.

## Files

| Path | Role |
|---|---|
| `app/page.tsx` | Landing page: pitch, pricing, FAQ |
| `app/success/page.tsx` | Post-checkout receipt; polls for the webhook's licence |
| `app/api/checkout/route.ts` | Creates the Stripe Checkout session |
| `app/api/stripe/webhook/route.ts` | Signature-verified; the only licence issuer |
| `app/api/activate/route.ts` | Key + device → signed entitlement token |
| `lib/licence.ts` | Key minting and Ed25519 signing — mirrors `LicenseClaims` in Swift |
| `lib/db.ts` | Postgres schema and queries |
| `lib/stripe.ts` | Stripe client; price → entitlement mapping |
| `lib/email.ts` | Licence delivery (no-ops without `RESEND_API_KEY`) |

## Known audit noise

`npm audit` reports `postcss` and `sharp` advisories inherited from Next itself.
`npm audit fix --force` "resolves" them by downgrading to `next@9` — don't.
Neither is reachable here: the site processes no attacker-supplied CSS and no
uploaded images. They clear when Next bumps its own dependencies.
