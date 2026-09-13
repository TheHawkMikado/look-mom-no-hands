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
    # SwiftPM resources (the speaker-verification Core ML model) land in
    # <NAME>_<NAME>.bundle next to the build product. Copy it into
    # Contents/Resources so the app finds it at Bundle.main.resourceURL, the
    # same way `swift test` finds it next to the binary. Missing bundle = the
    # model wasn't built; the app still runs (verification disables itself).
    local res_bundle
    res_bundle="$(dirname "${bin}")/${NAME}_${NAME}.bundle"
    if [ -d "${res_bundle}" ]; then
        cp -R "${res_bundle}" "${app}/Contents/Resources/"
    else
        echo "  ! ${res_bundle} missing — speaker model not bundled, voice verification will be off" >&2
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
