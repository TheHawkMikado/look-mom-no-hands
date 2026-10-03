#!/usr/bin/env bash
# One command, on the Mac that has the Developer ID certificate, to turn on
# automatic signed releases: it collects everything .github/workflows/release.yml
# needs, stores it as GitHub repository secrets, and (if you say yes) cuts the
# first signed release right away so every installed app updates itself.
#
#   ./Scripts/setup_release_secrets.sh
#
# What it gathers (DISTRIBUTION.md → Automatic releases):
#   MAC_SIGN_ID, MAC_CERT_P12_BASE64, MAC_CERT_PASSWORD   from your keychain
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD           you type two of them
#   VERCEL_TOKEN, VERCEL_PROJECT_ID, VERCEL_TEAM_ID,
#   VERCEL_DEPLOY_HOOK_URL                                from one Vercel token
#
# Options:
#   --p12 FILE      use a .p12 you exported from Keychain Access yourself
#                   (you'll be asked for its password) instead of exporting
#   --repo OWNER/R  the GitHub repo (default: this checkout's origin)
#   --no-release    store the secrets and stop; don't dispatch a release
#
# Nothing is written to disk except a temporary .p12 that is deleted on exit.
# Secrets go straight to GitHub over `gh`, which encrypts them client-side.
set -euo pipefail

P12=""
REPO=""
RELEASE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --p12) P12="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --no-release) RELEASE=0; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ "$(uname)" = Darwin ] || { echo "Run this on the Mac that has the Developer ID certificate." >&2; exit 1; }
cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- gh ----------
say "GitHub CLI"
if ! command -v gh >/dev/null; then
    command -v brew >/dev/null || fail "Install Homebrew (https://brew.sh) or the GitHub CLI (https://cli.github.com), then rerun."
    brew install gh
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "  Sign in to GitHub (a browser window will open)…"
    gh auth login --web --git-protocol https
fi
if [ -z "$REPO" ]; then
    REPO="$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
fi
gh repo view "$REPO" >/dev/null || fail "Can't see $REPO with this GitHub login."
ok "signed in, repo $REPO"

# ------------------------------------------------------------ Apple -----------
say "Developer ID certificate"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1 || true)"
[ -n "$IDENTITY" ] || fail "No 'Developer ID Application' certificate in your keychain. Create one at developer.apple.com → Certificates (Developer ID Application), double-click to install, rerun."
TEAM_ID="$(printf '%s' "$IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
[ -n "$TEAM_ID" ] || fail "Couldn't read the team id from: $IDENTITY"
ok "$IDENTITY"

P12_PASS="$(openssl rand -hex 16)"
if [ -n "$P12" ]; then
    [ -f "$P12" ] || fail "$P12 does not exist"
    read -r -s -p "  Password for $P12: " P12_PASS; echo
    cp "$P12" "$TMP/cert.p12"
else
    echo "  Exporting the certificate and its private key from your login keychain."
    echo "  macOS will ask for your login password, possibly once per item — click Allow."
    if ! security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 \
            -P "$P12_PASS" -o "$TMP/cert.p12" 2>"$TMP/export.err"; then
        cat "$TMP/export.err" >&2
        fail "Export failed. Export it by hand instead: Keychain Access → login → My Certificates → right-click '$IDENTITY' → Export → .p12, then rerun with --p12 <file>."
    fi
fi
# Prove the file is usable with that password before shipping it anywhere.
openssl pkcs12 -in "$TMP/cert.p12" -passin "pass:$P12_PASS" -nokeys -info >/dev/null 2>&1 \
    || fail "That .p12 can't be opened with the password given."
P12_B64="$(base64 -i "$TMP/cert.p12" | tr -d '\n')"
ok "certificate exported ($(wc -c < "$TMP/cert.p12" | tr -d ' ') bytes)"

say "Apple ID for notarisation"
DEFAULT_APPLE_ID="$(defaults read MobileMeAccounts Accounts 2>/dev/null | sed -nE 's/.*AccountID = "?([^";]+)"?;.*/\1/p' | head -1 || true)"
read -r -p "  Apple ID email [${DEFAULT_APPLE_ID:-none}]: " APPLE_ID
APPLE_ID="${APPLE_ID:-$DEFAULT_APPLE_ID}"
[ -n "$APPLE_ID" ] || fail "An Apple ID is required."
echo "  An APP-SPECIFIC password (not your Apple ID password):"
echo "  https://account.apple.com → Sign-In and Security → App-Specific Passwords → + (name it 'notary')."
read -r -s -p "  App-specific password: " APPLE_APP_PASSWORD; echo
[ -n "$APPLE_APP_PASSWORD" ] || fail "The app-specific password is required."
echo "  Checking it with Apple…"
xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APPLE_APP_PASSWORD" >/dev/null 2>"$TMP/notary.err" \
    || { cat "$TMP/notary.err" >&2; fail "Apple rejected that Apple ID / app-specific password / team ($TEAM_ID)."; }
ok "notarisation credentials accepted"

# ------------------------------------------------------------ Vercel ----------
say "Vercel (so /api/version tells every installed app)"
echo "  Create a token at https://vercel.com/account/tokens (scope: the team that owns nohandsapp, no expiry)."
read -r -s -p "  Vercel token: " VERCEL_TOKEN; echo
[ -n "$VERCEL_TOKEN" ] || fail "A Vercel token is required."
export VERCEL_TOKEN
# Find the nohandsapp project in the personal scope or any team, then make a
# production Deploy Hook so the release run can redeploy without guessing.
VERCEL_JSON="$(python3 - <<'PY'
import json, os, sys, urllib.request, urllib.parse
tok = os.environ["VERCEL_TOKEN"]
def api(method, path, body=None):
    req = urllib.request.Request("https://api.vercel.com" + path, method=method,
        headers={"authorization": f"Bearer {tok}", "content-type": "application/json"},
        data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req) as r: return json.load(r)
    except urllib.error.HTTPError as e:
        return {"_error": e.code, "_body": e.read().decode()[:300]}
teams = [None] + [t["id"] for t in api("GET", "/v2/teams").get("teams", [])]
found = None
for team in teams:
    q = "?search=nohandsapp" + (f"&teamId={team}" if team else "")
    for p in api("GET", "/v9/projects" + q).get("projects", []):
        if "nohands" in p["name"]:
            found = (team, p); break
    if found: break
if not found:
    print(json.dumps({"error": "no project with 'nohands' in its name is visible to this token"})); sys.exit(0)
team, proj = found
tq = f"?teamId={team}" if team else ""
hook = ""
res = api("POST", f"/v1/projects/{proj['id']}/deploy-hooks{tq}", {"name": "release.yml", "ref": "main"})
for h in (res.get("link") or {}).get("deployHooks", []):
    if h.get("name") == "release.yml" and h.get("url"): hook = h["url"]
if not hook:
    cur = api("GET", f"/v9/projects/{proj['id']}{tq}")
    for h in (cur.get("link") or {}).get("deployHooks", []):
        if h.get("url"): hook = h["url"]; break
print(json.dumps({"project_id": proj["id"], "project_name": proj["name"], "team_id": team or "", "hook": hook}))
PY
)"
VERCEL_PROJECT_ID="$(printf '%s' "$VERCEL_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("project_id",""))')"
[ -n "$VERCEL_PROJECT_ID" ] || fail "Vercel: $(printf '%s' "$VERCEL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error","unknown error"))')"
VERCEL_TEAM_ID="$(printf '%s' "$VERCEL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["team_id"])')"
VERCEL_DEPLOY_HOOK_URL="$(printf '%s' "$VERCEL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hook"])')"
ok "project $(printf '%s' "$VERCEL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["project_name"])') ($VERCEL_PROJECT_ID)${VERCEL_TEAM_ID:+, team $VERCEL_TEAM_ID}"
[ -n "$VERCEL_DEPLOY_HOOK_URL" ] && ok "deploy hook ready" || echo "  · no deploy hook (the release will redeploy the current production build instead)"

# ------------------------------------------------------------ store -----------
say "Storing ${REPO} secrets"
set_secret() { printf '%s' "$2" | gh secret set "$1" --repo "$REPO" >/dev/null && ok "$1"; }
set_secret MAC_SIGN_ID          "$IDENTITY"
set_secret MAC_CERT_P12_BASE64  "$P12_B64"
set_secret MAC_CERT_PASSWORD    "$P12_PASS"
set_secret APPLE_ID             "$APPLE_ID"
set_secret APPLE_TEAM_ID        "$TEAM_ID"
set_secret APPLE_APP_PASSWORD   "$APPLE_APP_PASSWORD"
set_secret VERCEL_TOKEN         "$VERCEL_TOKEN"
set_secret VERCEL_PROJECT_ID    "$VERCEL_PROJECT_ID"
if [ -n "$VERCEL_TEAM_ID" ]; then set_secret VERCEL_TEAM_ID "$VERCEL_TEAM_ID"; fi
if [ -n "$VERCEL_DEPLOY_HOOK_URL" ]; then set_secret VERCEL_DEPLOY_HOOK_URL "$VERCEL_DEPLOY_HOOK_URL"; fi

# The team pinned in the app must match the certificate or no update will
# ever install. Loud, not fatal: the fix is a one-line change in AppUpdater.
PINNED="$(sed -nE 's/.*subject\.OU\] = \\"([A-Z0-9]{10})\\".*/\1/p' Sources/LookMomNoHands/AppUpdater.swift | head -1 || true)"
if [ -n "$PINNED" ] && [ "$PINNED" != "$TEAM_ID" ]; then
    echo "  ! AppUpdater.requirement pins team $PINNED but this certificate is team $TEAM_ID — update that string before releasing." >&2
fi

# ------------------------------------------------------------ release ---------
if [ "$RELEASE" = 1 ]; then
    say "First signed release"
    read -r -p "  Cut a signed release from main now? Every installed app will update itself. [Y/n] " yn
    case "${yn:-Y}" in
        [Yy]*)
            gh workflow run release.yml --repo "$REPO" --ref main -f notes="Signed, self-updating releases are on."
            ok "release run started — watch it: gh run watch --repo $REPO   (or the Actions tab)"
            echo "  When it finishes, every Mac running the app sees the new version on its next"
            echo "  check (within the hour) and installs it when idle. Open the menu → Update now to skip the wait."
            ;;
        *) echo "  Skipped. The next merge to main releases on its own." ;;
    esac
fi
echo
echo "Done. From now on every merge to main is signed, notarised, published and pushed to every installed app."
