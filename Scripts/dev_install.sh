#!/usr/bin/env bash
# Fast dev build + install to /Applications, signed with the STABLE self-signed
# identity from dev_signing_setup.sh so TCC permissions persist across rebuilds.
# Native arch only (fast). Use package_release.sh for the universal, notarizable DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/common.sh

# Assemble AND sign entirely under /tmp — never inside the project's build/ dir.
# That dir lives under ~/Documents, which is iCloud-synced: the file provider can
# wedge `rm -rf` on a stale .app bundle (a 65535-link-count directory that hangs
# forever), which stalled every install. /tmp is a plain local volume, so bundle
# churn there is instant and can't be corrupted by iCloud.
WORK="$(mktemp -d /tmp/lmnh-dev.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
APP="${WORK}/${DISPLAY}.app"
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

# iCloud re-attaches xattrs inside ~/Documents faster than we can strip them, and
# Developer ID signing hard-fails on com.apple.FinderInfo — but ${APP} is already
# in /tmp, so sign it in place with no cross-volume copy.
if security find-certificate -c "${IDENTITY%% (*}" >/dev/null 2>&1 || security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY}"; then
    echo "▸ signing with stable identity '${IDENTITY}' (permissions will persist)"
    sign_app "${APP}" "${IDENTITY}"
else
    echo "▸ '${IDENTITY}' not found — run Scripts/dev_signing_setup.sh first to stop"
    echo "  permissions resetting. Falling back to ad-hoc for now."
    sign_app "${APP}" "-"
fi

echo "▸ installing to ${DEST}"
pkill -x "${NAME}" 2>/dev/null || true
sleep 0.5
rm -rf "${DEST}"
cp -R "${APP}" "${DEST}"
open "${DEST}"
echo "✓ installed and launched"
