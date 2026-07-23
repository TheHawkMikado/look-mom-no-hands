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

1. Create three **recurring Prices billed every 1 week** and copy the `price_…`
   ids into `STRIPE_PRICE_SOLO`, `STRIPE_PRICE_FAMILY`, `STRIPE_PRICE_UNLIMITED`.
   They must be recurring — checkout runs in subscription mode for every plan,
   and a one-off price will simply fail. The plan → entitlement mapping lives in
   `lib/stripe.ts`, server-side, so the browser can never ask for terms it
   didn't pay for.

   | Plan | Price | Computers | Phones | Notes |
   |---|---|---|---|---|
   | Solo | $3/wk | 2 | 1 | |
   | Family | $9/wk | 9 | 9 | |
   | Unlimited | $27/wk | unlimited | unlimited | resell rights, 27 sub-users |

2. Add a webhook endpoint at `https://nohandsapp.com/api/stripe/webhook`
   subscribed to `checkout.session.completed`, **`invoice.paid`** and
   `customer.subscription.deleted`. Copy the signing secret into
   `STRIPE_WEBHOOK_SECRET`.

   `invoice.paid` is not optional. Licences are only ever valid to the end of
   the period Stripe has actually collected for, so it is the event that keeps
   paying subscribers working. Miss it and everyone stops after week one.

3. Turn on **Stripe Tax** if you want VAT/sales tax calculated (`automatic_tax`
   is already enabled in the checkout call).

> **Fees bite harder at $3.** Stripe's 2.9% + 30¢ costs about 39¢ on a $3
> charge — roughly 13% of revenue, versus ~3.5% on a monthly $13. Weekly billing
> also means 4× the charges and 4× the chances of a card declining. Worth
> pricing in, or offering a monthly option alongside.

### Not built yet: phones and resell sub-users

The catalogue sells both; neither is implemented.

- **Phones.** The app is a macOS menu-bar app and activation is keyed on a Mac's
  hashed `IOPlatformUUID`. There is no iOS client, so a phone allowance can't be
  spent or enforced. `lib/stripe.ts` records the counts, ready for when one
  exists.
- **Resell sub-users.** Unlimited promises 27 Solo sub-users and $1/wk for each
  one after. Minting sub-licences under a parent, and metering that overage back
  to Stripe, is not written. Selling Unlimited today means issuing those keys by
  hand and invoicing overage yourself.

### 4. Vercel

Live as the **`nohandsapp`** project, root directory **`web`** — the Swift app
shares this repo and Vercel must not try to build it. Add every variable from
`.env.example` under Settings → Environment Variables.

Three things that cost time the first time round:

- **Deployment Protection blocks Stripe.** New projects default to
  `ssoProtection: all_except_custom_domains`, so `*.vercel.app` URLs answer
  `401` to everyone — including Stripe's webhooks. Custom domains are exempt, so
  production is fine, but never point a webhook at a preview URL. To exercise a
  protected deployment from a script, create an automation bypass
  (`vercel project protection enable --protection-bypass`) and send the secret as
  an `x-vercel-protection-bypass` header.
- **Cloudflare must not proxy the apex.** DNS lives on Cloudflare; Vercel's
  record is returned with `disableProxy: true`, meaning grey cloud / DNS-only.
  Leaving the orange cloud on puts two CDNs in series and breaks certificate
  issuance.
- **Push-to-deploy needs the Vercel GitHub App.** A project can hold a valid git
  link — and Vercel can still clone and build from it via the API — while no
  webhook exists, so pushes appear to do nothing. If a push doesn't produce a
  deployment, install/authorise the Vercel app for the repo in GitHub rather
  than re-linking the project.

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
