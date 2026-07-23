#!/usr/bin/env bash
# Generates the Ed25519 keypair that signs license tokens.
#
# Run this ONCE. The private half goes into Vercel and nowhere else; the public
# half gets pasted into LicenseConfig.publicKeyHex in the Swift source.
#
# Rotating the key invalidates every token already issued to customers, so if you
# ever have to, ship the new public key and have the site re-issue tokens for
# existing orders before you flip it.
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

openssl genpkey -algorithm ed25519 -out "${TMP}/priv.pem" 2>/dev/null

# Ed25519 DER wraps the raw 32-byte key behind a fixed 16-byte header (private)
# and a 12-byte header (public); tail those off to get the raw bytes both the
# Swift CryptoKit side and the Node side expect.
PRIV_HEX="$(openssl pkey -in "${TMP}/priv.pem" -outform DER \
    | tail -c 32 | xxd -p -c 64)"
PUB_HEX="$(openssl pkey -in "${TMP}/priv.pem" -pubout -outform DER \
    | tail -c 32 | xxd -p -c 64)"

cat <<EOF

  Ed25519 license keypair
  ═══════════════════════

  1. PUBLIC key — paste into LicenseConfig.publicKeyHex
     (Sources/LookMomNoHands/LicenseStore.swift). Safe to commit.

     ${PUB_HEX}

  2. PRIVATE key — set as LICENSE_SIGNING_KEY in the Vercel project
     (Settings → Environment Variables). NEVER commit this.

     ${PRIV_HEX}

  Store the private key in your password manager too. If you lose it you cannot
  issue licenses to new customers without rotating and re-issuing to old ones.

EOF
