#!/usr/bin/env bash
# Sourced by every build script — single home for identity strings and the
# bundle/sign recipe, so the entry points can't drift apart.
# (Swift-side identity constants live in Sources/LookMomNoHands/Models.swift.)

NAME="LookMomNoHands"                 # binary / internal target name
DISPLAY="Look Ma, No Hands"           # user-facing app name
DEV_IDENTITY="Look Ma Dev"            # stable self-signed cert (dev_signing_setup.sh)
DMG_BASENAME="LookMaNoHands"          # frozen so download names stay stable

# assemble_app <binary> <app-path> — minimal bundle around a single binary
# The .icns is committed (Scripts/render_icon.sh regenerates it from
# Assets/icon.svg), so building never depends on a rasteriser being installed.
assemble_app() {
    local bin="$1" app="$2"
    rm -rf "${app}"
    mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"
    cp "${bin}" "${app}/Contents/MacOS/${NAME}"
    cp App/Info.plist "${app}/Contents/Info.plist"
    if [ -f Assets/AppIcon.icns ]; then
        cp Assets/AppIcon.icns "${app}/Contents/Resources/AppIcon.icns"
    else
        echo "  ! Assets/AppIcon.icns missing — run Scripts/render_icon.sh" >&2
    fi
}

# sign_app <app-path> <identity> [extra codesign flags...] — identity "-" = ad-hoc.
# Strips xattrs first: iCloud re-attaches com.apple.FinderInfo inside ~/Documents
# and Developer ID signing hard-fails on it.
sign_app() {
    local app="$1" identity="$2"
    shift 2
    xattr -cr "${app}" 2>/dev/null || true
    codesign --force --options runtime "$@" \
        --entitlements App/LookMomNoHands.entitlements \
        --sign "${identity}" "${app}"
}
