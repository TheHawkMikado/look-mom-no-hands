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
    # The Chrome extension rides along unpacked; the app copies it to
    # Application Support on launch and Settings points Chrome at that copy.
    if [ -d chrome-extension ]; then
        rm -rf "${app}/Contents/Resources/chrome-extension"
        rsync -a --exclude test --exclude '.*' chrome-extension/ "${app}/Contents/Resources/chrome-extension/"
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

# notary_configured — true when notarytool can be run, and sets NOTARY_ARGS to
# the matching credential flags: a stored keychain profile (NOTARY_PROFILE) or
# the raw Apple ID credentials (APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD).
NOTARY_ARGS=()
notary_configured() {
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE}")
        return 0
    fi
    if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
        NOTARY_ARGS=(--apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}" --password "${APPLE_APP_PASSWORD}")
        return 0
    fi
    return 1
}
