#!/usr/bin/env bash
# Cuts a release the update checker can actually see.
#
# The app polls https://nohandsapp.com/api/version and compares the returned
# `version` against its own CFBundleShortVersionString. So a release is only
# "real" when all four of these move together:
#
#   1. App/Info.plist          — the version the built app reports about itself
#   2. build/…-<version>.dmg   — a signed, notarised universal build
#   3. a GitHub release        — where download_url (releases/latest) resolves to
#   4. LATEST_APP_VERSION      — what /api/version tells every installed app
#
# Miss any one and installed copies keep saying "up to date" forever. This does
# 1–3 and prints the exact command for 4 (a Vercel env change is deliberately
# left as a deliberate act — it flips the update prompt on for everyone at once).
#
# Versions are V<milestone>.<update>.<YYMMDD>.<commit> — you pass the first
# two; today's date and HEAD's short hash are appended:
#
#   ./Scripts/release.sh 0.04        →  0.04.260901.a1b2c3d   (tag v0.04.260901.a1b2c3d)
#
# Ordering lives in the first three components; the commit id is an IDENTITY —
# "which code are you running" in one string. Ship twice in one day and the
# hash is what separates the two (the app treats a differing commit under an
# equal base as "the server has a respin").
#
# Usage:
#   SIGN_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=LookMaNotary \
#     ./Scripts/release.sh 0.02 --notes "See every window on every Space."
#
# Flags:
#   --notes "…"        what's-new text, shown under the update nudge
#   --date YYMMDD      override the date component (default: today)
#   --allow-unsigned   package without Developer ID (Gatekeeper will warn users)
#   --dry-run          do everything local, push and publish nothing
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/common.sh

MARKETING=""
DATESTAMP="$(date +%y%m%d)"
NOTES=""
ALLOW_UNSIGNED=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --notes) NOTES="${2:-}"; shift 2 ;;
        --date) DATESTAMP="${2:-}"; shift 2 ;;
        --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        -*) echo "unknown flag: $1" >&2; exit 1 ;;
        *) MARKETING="$1"; shift ;;
    esac
done

die() { echo "✗ $*" >&2; exit 1; }

[ -n "${MARKETING}" ] || die "no version given (e.g. ./Scripts/release.sh 0.02)"

# Accept a bare marketing version ("0.04") or a full one with the commit
# component ("0.04.260901.a1b2c3d") so a re-run of a printed command does the
# same thing rather than double-stamping. The commit component is always
# recomputed from HEAD — the version NAMES the code, it doesn't choose it.
if [[ "${MARKETING}" =~ ^([0-9]+\.[0-9]+)\.([0-9]{6})(\.[0-9a-f]+)?$ ]]; then
    DATESTAMP="${BASH_REMATCH[2]}"
    MARKETING="${BASH_REMATCH[1]}"
fi

[[ "${MARKETING}" =~ ^[0-9]+\.[0-9]+$ ]] \
    || die "marketing version must look like 0.04 — milestone.update, both numeric"
[[ "${DATESTAMP}" =~ ^[0-9]{6}$ ]] || die "--date must be YYMMDD, got '${DATESTAMP}'"

# V<milestone>.<update>.<date>.<commit> — the commit id of the code being
# released (HEAD before the bump commit this script adds). "Which version are
# you running?" now answers "which code are you running" in one string. The
# commit component is an identity, not an ordinal: the app treats a differing
# commit under an equal milestone.update.date as "the server has a respin".
COMMIT="$(git rev-parse --short HEAD)"
VERSION="${MARKETING}.${DATESTAMP}.${COMMIT}"

# --- preflight -------------------------------------------------------------
# A release is a public artefact; refuse to cut one from a state you can't
# reproduce from origin later.
command -v gh >/dev/null || die "gh CLI not found — needed to publish the release"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "${BRANCH}" = "main" ] || die "on branch '${BRANCH}' — release from main"

git fetch origin --quiet
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "local main and origin/main differ — pull/push first (this is exactly the drift that leaves a release un-cut)"

# The commit id makes collisions meaningful: the same version can only exist
# if this exact code was already released (or a dry run left its local tag —
# the undo it prints includes the tag -d for a reason).
git rev-parse "v${VERSION}" >/dev/null 2>&1 \
    && die "v${VERSION} already exists — this exact commit was already released.
    (After a dry run, undo BOTH halves: git tag -d v${VERSION} && git reset --hard HEAD~1)"

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist)"

# Mirror UpdateChecker.compare: dot-separated components read as base-10 numbers
# (10# so a leading zero isn't parsed as octal), shorter padded with zeros.
# A release that doesn't compare *newer* than the last one is invisible to every
# installed app no matter how correctly it's published — catch that here.
is_older() {
    local -a l r
    IFS=. read -ra l <<< "$1"
    IFS=. read -ra r <<< "$2"
    local n=$(( ${#l[@]} > ${#r[@]} ? ${#l[@]} : ${#r[@]} ))
    local i a b
    for (( i = 0; i < n; i++ )); do
        # Leading digits only, matching the Swift side's prefix(while:isNumber):
        # a component like "0-beta" reads as 0 rather than blowing up the
        # arithmetic, so a malformed version can only compare equal-or-older.
        a="${l[i]:-0}"; a="${a%%[!0-9]*}"
        b="${r[i]:-0}"; b="${b%%[!0-9]*}"
        a=$(( 10#${a:-0} )); b=$(( 10#${b:-0} ))
        (( a != b )) && return $(( a < b ? 0 : 1 ))
    done
    return 1
}

# Ordering lives in the FIRST THREE components (milestone.update.date); the
# commit id is an identity the app treats as "differs = the server has a respin
# I don't". So: base must not go backwards, and an equal base is fine exactly
# when the commit differs (a same-day respin) — which the tag check above
# already guarantees.
base3() { echo "$1" | cut -d. -f1-3; }
[ "${CURRENT}" != "${VERSION}" ] \
    || die "version is identical to the running ${CURRENT} — every installed app would read it as 'up to date'"
if [ "$(base3 "${CURRENT}")" = "$(base3 "${VERSION}")" ]; then
    echo "  same-day respin: ${CURRENT} → ${VERSION} (commit id is the tiebreaker)"
else
    is_older "$(base3 "${CURRENT}")" "$(base3 "${VERSION}")" \
        || die "${VERSION} does not compare newer than the current ${CURRENT} — every installed app would keep reporting 'up to date'"
fi

if [ -z "${SIGN_ID:-}" ] && [ "${ALLOW_UNSIGNED}" = 0 ]; then
    die "SIGN_ID unset — an unsigned DMG makes every downloader clear a Gatekeeper block.
    Set SIGN_ID + NOTARY_PROFILE (see DISTRIBUTION.md), or pass --allow-unsigned if that's intended."
fi

SUFFIX=""
[ "${DRY_RUN}" = 1 ] && SUFFIX=" (dry run)"
echo "▸ ${CURRENT} → ${VERSION}${SUFFIX}"

# --- 1. bump ---------------------------------------------------------------
# CFBundleVersion is the monotonic build number macOS uses to order installs;
# it has to climb even when the marketing version does.
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' App/Info.plist)"
NEXT_BUILD=$(( BUILD + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" App/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_BUILD}" App/Info.plist
echo "  Info.plist: ${VERSION} (build ${NEXT_BUILD})"

# Any exit past here leaves an edited plist behind; put it back so a retry starts
# from the same place rather than a half-bumped tree. This is EXIT rather than
# ERR on purpose: the guards below bail via `die`, and `exit` does not fire an
# ERR trap, so an ERR trap would sail straight past exactly the failures it
# exists for. Once the bump is committed the checkout is a harmless no-op, so
# the success path needs no special case.
restore_plist() { git checkout -- App/Info.plist 2>/dev/null || true; }
trap restore_plist EXIT

# --- 2. build --------------------------------------------------------------
./Scripts/package_release.sh

DMG="build/${DMG_BASENAME}-${VERSION}.dmg"
[ -f "${DMG}" ] || die "expected ${DMG} — package_release.sh did not produce it"

if [ -n "${SIGN_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun stapler validate "${DMG}" >/dev/null \
        || die "${DMG} has no stapled notarisation ticket — do not publish it"
fi

# --- 3. tag + publish ------------------------------------------------------
# The EXIT trap stays armed: committing the bump makes it a no-op, and if the
# commit itself fails the plist still needs putting back.
git add App/Info.plist
git commit -qm "Release v${VERSION}"
git tag -a "v${VERSION}" -m "v${VERSION}"

if [ "${DRY_RUN}" = 1 ]; then
    echo
    echo "✓ dry run: built ${DMG}, committed and tagged v${VERSION} locally."
    echo "  Nothing pushed or published. Undo with:"
    echo "    git tag -d v${VERSION} && git reset --hard HEAD~1"
    exit 0
fi

git push origin main
git push origin "v${VERSION}"

gh release create "v${VERSION}" "${DMG}" \
    --title "${DISPLAY} v${VERSION}" \
    --notes "${NOTES:-Release v${VERSION}}"

# --- 4. the step that actually tells installed apps ------------------------
# Until LATEST_APP_VERSION moves, /api/version keeps serving the old number and
# every installed copy stays convinced it's current, DMG on GitHub or not.
cat <<EOF

✓ Published v${VERSION} — https://github.com/TheHawkMikado/look-mom-no-hands/releases/tag/v${VERSION}

  One step left, and it's the one that reaches installed apps. Set on Vercel
  (Project → Settings → Environment Variables → Production), then redeploy:

    LATEST_APP_VERSION=${VERSION}
    LATEST_APP_NOTES=${NOTES:-}

  Or with the Vercel CLI:

    printf '%s' '${VERSION}' | vercel env add LATEST_APP_VERSION production --force
    vercel --prod

  Then confirm what every app will see:

    curl -s https://nohandsapp.com/api/version

EOF
