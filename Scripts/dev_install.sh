#!/usr/bin/env bash
# Fast dev build + install to /Applications, signed with the STABLE self-signed
# identity from dev_signing_setup.sh so TCC permissions persist across rebuilds.
# Native arch only (fast). Use package_release.sh for the universal, notarizable DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="LookMomNoHands"
DISPLAY="Look Ma, No Hands"
APP="build/${NAME}.app"
DEST="/Applications/${DISPLAY}.app"
IDENTITY="Look Ma Dev"

echo "▸ swift build -c release"
swift build -c release >/dev/null

BIN=".build/release/${NAME}"
[ -f "${BIN}" ] || { echo "build product missing"; exit 1; }

echo "▸ assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp "${BIN}" "${APP}/Contents/MacOS/${NAME}"
cp App/Info.plist "${APP}/Contents/Info.plist"

if security find-certificate -c "${IDENTITY}" >/dev/null 2>&1; then
    echo "▸ signing with stable identity '${IDENTITY}' (permissions will persist)"
    codesign --force --deep --options runtime \
        --entitlements App/LookMomNoHands.entitlements \
        --sign "${IDENTITY}" "${APP}"
else
    echo "▸ '${IDENTITY}' not found — run Scripts/dev_signing_setup.sh first to stop"
    echo "  permissions resetting. Falling back to ad-hoc for now."
    codesign --force --deep --options runtime \
        --entitlements App/LookMomNoHands.entitlements --sign - "${APP}"
fi

echo "▸ installing to ${DEST}"
pkill -x "${NAME}" 2>/dev/null || true
sleep 0.5
rm -rf "${DEST}"
cp -R "${APP}" "${DEST}"
open "${DEST}"
echo "✓ installed and launched"
