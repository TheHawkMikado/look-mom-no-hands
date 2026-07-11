#!/usr/bin/env bash
# Fast dev build + install to /Applications, signed with the STABLE self-signed
# identity from dev_signing_setup.sh so TCC permissions persist across rebuilds.
# Native arch only (fast). Use package_release.sh for the universal, notarizable DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/common.sh

APP="build/${NAME}.app"
DEST="/Applications/${DISPLAY}.app"

# Prefer the real Developer ID so dev builds share the notarized app's identity —
# TCC grants then survive both dev reinstalls AND DMG installs. Fall back to the
# self-signed dev identity, then ad-hoc.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')"
else
    IDENTITY="${DEV_IDENTITY}"
fi

echo "▸ swift build -c release"
swift build -c release >/dev/null

BIN=".build/release/${NAME}"
[ -f "${BIN}" ] || { echo "build product missing"; exit 1; }

echo "▸ assembling ${APP}"
assemble_app "${BIN}" "${APP}"

# Sign in /tmp — iCloud re-attaches xattrs inside ~/Documents faster than we can
# strip them (same workaround as package_release.sh).
WORK="$(mktemp -d /tmp/lmnh-dev.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
SIGNAPP="${WORK}/${DISPLAY}.app"
cp -R "${APP}" "${SIGNAPP}"

if security find-certificate -c "${IDENTITY%% (*}" >/dev/null 2>&1 || security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY}"; then
    echo "▸ signing with stable identity '${IDENTITY}' (permissions will persist)"
    sign_app "${SIGNAPP}" "${IDENTITY}"
else
    echo "▸ '${IDENTITY}' not found — run Scripts/dev_signing_setup.sh first to stop"
    echo "  permissions resetting. Falling back to ad-hoc for now."
    sign_app "${SIGNAPP}" "-"
fi

echo "▸ installing to ${DEST}"
pkill -x "${NAME}" 2>/dev/null || true
sleep 0.5
rm -rf "${DEST}"
cp -R "${SIGNAPP}" "${DEST}"
open "${DEST}"
echo "✓ installed and launched"
