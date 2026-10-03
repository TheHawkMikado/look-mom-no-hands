#!/usr/bin/env bash
# One command: Paperclip on this Mac, your company and starter agents created,
# wired to your No Hands account, and kept running at login. Idempotent —
# rerun it any time; it only does what is still missing.
#
#   ./Scripts/paperclip/setup.sh
#
# Options:
#   --api URL     the No Hands service to register with (default https://nohandsapp.com)
#   --no-login    don't install the launch agents (run bridge.mjs yourself)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

API="https://nohandsapp.com"
LOGIN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --api) API="${2%/}"; shift 2 ;;
    --no-login) LOGIN=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- node ---------
say "Node.js"
need_node() {
  command -v node >/dev/null || return 1
  local major; major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$major" -ge 20 ]
}
if ! need_node; then
  if command -v brew >/dev/null; then
    echo "  Installing Node.js with Homebrew…"
    brew install node >/dev/null
  else
    fail "Node.js 20+ is required. Install it from https://nodejs.org (or Homebrew), then rerun."
  fi
fi
need_node || fail "Node.js 20+ is required (found $(node -v))."
ok "node $(node -v)"

# ------------------------------------------------------- anthropic key ---------
say "AI key for the agents"
ENV_FILE="$HERE/.env"
current_key=""
if [ -f "$ENV_FILE" ]; then
  current_key="$(sed -n 's/^ANTHROPIC_API_KEY=//p' "$ENV_FILE" | head -1)"
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "$current_key" ]; then
  echo "  The starter agents draft with Anthropic. Paste your API key (sk-ant-…),"
  echo "  or press Enter to skip — they'll post placeholder drafts until you add one."
  read -r -s -p "  Anthropic API key: " ANTHROPIC_API_KEY; echo
  export ANTHROPIC_API_KEY
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -f "$ENV_FILE" ]; then
  # .env already exists (from an earlier run): put the key in it.
  if grep -q '^ANTHROPIC_API_KEY=' "$ENV_FILE"; then
    sed -i '' "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}|" "$ENV_FILE" 2>/dev/null \
      || sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}|" "$ENV_FILE"
  else
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "$ENV_FILE"
  fi
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "$current_key" ]; then ok "key on file"; else echo "  · skipped (placeholder drafts)"; fi

# ------------------------------------------------------------ paperclip --------
say "Paperclip"
"$HERE/up.sh" up
ok "running on http://localhost:${PAPERCLIP_PORT:-3100}"

say "Company and starter agents"
node "$HERE/bootstrap.mjs" --api "$API" | sed 's/^/  /'

# ------------------------------------------------------------- account ---------
say "Connect to your No Hands account"
TOKEN=""
if [ -f "$HERE/.connection.json" ]; then
  TOKEN="$(node -e 'const c=require(process.argv[1]); process.stdout.write(c.token||"")' "$HERE/.connection.json" 2>/dev/null || true)"
fi
if [ -n "$TOKEN" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $TOKEN" "$API/api/app/paperclip/connection" || echo 000)"
  if [ "$code" = "200" ]; then ok "already connected"; else TOKEN=""; echo "  · the saved token no longer works — signing in again"; fi
fi
if [ -z "$TOKEN" ]; then
  URL="$API/app/login?client=bridge"
  echo "  Sign in at $URL"
  echo "  and paste the token it shows you."
  if command -v open >/dev/null; then open "$URL"; fi
  read -r -s -p "  Token: " TOKEN; echo
  TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
  [ -n "$TOKEN" ] || fail "No token — rerun ./Scripts/paperclip/setup.sh when you have it."
  NOHANDS_APP_TOKEN="$TOKEN" node "$HERE/bootstrap.mjs" --api "$API" | sed 's/^/  /'
fi

# --------------------------------------------------------------- login ---------
if [ "$LOGIN" = 1 ] && [ "$(uname)" = Darwin ]; then
  say "Start at login"
  "$HERE/install-launchagents.sh" | sed 's/^/  /'
  sleep 3
  if "$HERE/up.sh" status >/dev/null 2>&1; then ok "Paperclip is up under launchd"; else fail "Paperclip did not come back up under launchd — see $HERE/data/paperclip.log"; fi
  if pgrep -f "$HERE/bridge.mjs" >/dev/null 2>&1; then ok "bridge is running"; else echo "  ! bridge not seen yet — check $HERE/data/bridge.log"; fi
else
  say "Bridge"
  echo "  Keep this running whenever you want tasks to flow:"
  echo "    node $HERE/bridge.mjs"
fi

echo
echo "Done. Paperclip is the team behind the assistant; you never have to open its board."
echo "  Board (if you're curious): http://localhost:${PAPERCLIP_PORT:-3100}"
echo "  Status:  ./Scripts/paperclip/up.sh status      Logs: $HERE/data/*.log"
echo "  Remove:  ./Scripts/paperclip/install-launchagents.sh --uninstall"
