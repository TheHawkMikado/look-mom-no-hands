#!/usr/bin/env bash
# Assembles a runnable, ad-hoc-signed .app bundle from the SwiftPM build product.
# A real bundle + signature is what lets macOS show the mic/speech permission
# prompts and remember Accessibility grants.
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/common.sh

CONFIG="${1:-release}"
APP="build/${NAME}.app"

echo "▸ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN=".build/${CONFIG}/${NAME}"
[ -f "${BIN}" ] || { echo "build product not found at ${BIN}"; exit 1; }

echo "▸ assembling ${APP}"
assemble_app "${BIN}" "${APP}"

echo "▸ ad-hoc code signing"
sign_app "${APP}" "-"

echo "✓ built ${APP}"
echo
echo "Run it:            open ${APP}"
echo "Then grant in System Settings → Privacy & Security:"
echo "  • Microphone, Speech Recognition (prompted on first launch)"
echo "  • Accessibility      (add ${NAME})   — required to click/type"
