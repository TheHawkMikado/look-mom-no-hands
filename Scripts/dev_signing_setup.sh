#!/usr/bin/env bash
# Creates a STABLE self-signed code-signing identity for local development.
#
# Why: ad-hoc signing (`codesign --sign -`) gives the app a new cryptographic
# identity on every rebuild, so macOS TCC forgets Microphone / Speech /
# Accessibility grants each time you reinstall. Signing with a fixed self-signed
# certificate keeps the identity constant across rebuilds, so permissions stick
# until you deliberately reset them. (This cert is for LOCAL use only — public
# distribution still needs a real Developer ID + notarization.)
set -euo pipefail
source "$(dirname "$0")/common.sh"

IDENTITY="${DEV_IDENTITY}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "✓ signing identity '$IDENTITY' already exists"
    exit 0
fi

echo "▸ creating self-signed code-signing identity '$IDENTITY'"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# macOS ships LibreSSL, whose PKCS12 default (RC2/3DES/SHA1) is already readable by
# `security import`. A non-empty password is required — an empty one trips the MAC check.
P12PASS="devpass"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$P12PASS" >/dev/null 2>&1

# -A lets codesign use the private key without a per-build keychain prompt.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PASS" -A -T /usr/bin/codesign >/dev/null

echo "✓ created '$IDENTITY' — dev_install.sh will sign with it automatically"
