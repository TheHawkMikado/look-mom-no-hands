#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) .app and packages a drag-to-install .dmg.
#
# Universal binary: each arch is built separately and lipo'd together — works with
# just the Command Line Tools (the combined `swift build --arch a --arch b` form
# needs full Xcode; this doesn't).
#
# Assembly and signing happen in a temp dir under /tmp: this repo lives in
# ~/Documents, which iCloud syncs, and the file provider re-attaches
# com.apple.FinderInfo xattrs faster than we can strip them — Developer ID
# signing hard-fails on those. Outside iCloud, the bundle stays clean.
#
# Signing: full Developer ID + notarization when credentials are present;
# otherwise ad-hoc (installable, but Gatekeeper warns recipients).
#
# Environment variables:
#   SIGN_ID          "Developer ID Application: Your Name (TEAMID)"  — enables real signing
#   NOTARY_PROFILE   name of a stored notarytool keychain profile     — enables notarization
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/common.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist)"
DMG_NAME="${DMG_BASENAME}-${VERSION}.dmg"

echo "▸ building arm64"
swift build -c release --arch arm64 >/dev/null
echo "▸ building x86_64"
swift build -c release --arch x86_64 >/dev/null

ARM=".build/arm64-apple-macosx/release/${NAME}"
X86=".build/x86_64-apple-macosx/release/${NAME}"
[ -f "${ARM}" ] && [ -f "${X86}" ] || { echo "per-arch binaries missing"; exit 1; }

WORK="$(mktemp -d /tmp/lmnh-release.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
APP="${WORK}/${DISPLAY}.app"
DMG="${WORK}/${DMG_NAME}"

echo "▸ assembling universal app in ${WORK} (outside iCloud)"
UNIBIN="${WORK}/${NAME}"
lipo -create "${ARM}" "${X86}" -output "${UNIBIN}"
assemble_app "${UNIBIN}" "${APP}"
echo "  archs: $(lipo -archs "${APP}/Contents/MacOS/${NAME}")"

if [ -n "${SIGN_ID:-}" ]; then
    echo "▸ signing with Developer ID: ${SIGN_ID}"
    sign_app "${APP}" "${SIGN_ID}" --timestamp
    codesign --verify --strict --verbose=2 "${APP}"
else
    echo "▸ no SIGN_ID set — ad-hoc signing (recipients will see a Gatekeeper warning)"
    sign_app "${APP}" "-"
fi

echo "▸ building ${DMG_NAME}"
STAGE="${WORK}/stage"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "${DISPLAY}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null

# Sign the DMG container too (before notarization) so the disk image itself
# passes Gatekeeper assessment, not just the app inside it.
if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --timestamp --sign "${SIGN_ID}" "${DMG}"
fi

if [ -n "${SIGN_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▸ notarizing (this can take a few minutes)"
    xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
    echo "▸ stapling ticket"
    xcrun stapler staple "${DMG}"
    xcrun stapler validate "${DMG}"
    NOTARIZED=1
else
    NOTARIZED=0
fi

mkdir -p build
mv "${DMG}" "build/${DMG_NAME}"
rm -rf "build/${NAME}.app"
cp -R "${APP}" "build/${NAME}.app"   # local copy for dev_install-style use

if [ "${NOTARIZED}" = 1 ]; then
    echo "✓ notarized DMG — anyone can download and open it cleanly:"
else
    echo "✓ DMG ready (NOT notarized):"
    echo "  Recipients: right-click the app → Open on first launch."
fi
echo "  build/${DMG_NAME}"
