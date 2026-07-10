#!/usr/bin/env bash
# Assembles a runnable, ad-hoc-signed .app bundle from the SwiftPM build product.
# A real bundle + signature is what lets macOS show the mic/speech permission
# prompts and remember Accessibility/Screen Recording grants.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
NAME="LookMomNoHands"
APP="build/${NAME}.app"

echo "▸ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN=".build/${CONFIG}/${NAME}"
[ -f "${BIN}" ] || { echo "build product not found at ${BIN}"; exit 1; }

echo "▸ assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${NAME}"
cp App/Info.plist "${APP}/Contents/Info.plist"

echo "▸ ad-hoc code signing"
codesign --force --deep --sign - \
    --entitlements App/LookMomNoHands.entitlements \
    --options runtime "${APP}"

echo "✓ built ${APP}"
echo
echo "Run it:            open ${APP}"
echo "Then grant in System Settings → Privacy & Security:"
echo "  • Microphone, Speech Recognition (prompted on first launch)"
echo "  • Accessibility      (add ${NAME})   — required to click/type"
echo "  • Screen Recording   (add ${NAME})   — required for screenshots"
