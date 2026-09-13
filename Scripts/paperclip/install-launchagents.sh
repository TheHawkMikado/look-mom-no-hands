#!/usr/bin/env bash
# Keep Paperclip and the bridge running on a Mac laptop: start at login, restart
# if they die, no terminal window. Idempotent.
#
#   ./Scripts/paperclip/install-launchagents.sh             install + start
#   ./Scripts/paperclip/install-launchagents.sh --uninstall
#
# Run bootstrap.mjs (with your token) BEFORE this so .connection.json exists;
# the bridge won't start without it. Logs: Scripts/paperclip/data/*.log
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
PC_LABEL="com.nohandsapp.paperclip"
BR_LABEL="com.nohandsapp.paperclip-bridge"
mkdir -p "$AGENTS" "$HERE/data"

unload() { launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true; }

if [ "${1:-}" = "--uninstall" ]; then
  unload "$PC_LABEL"; unload "$BR_LABEL"
  rm -f "$AGENTS/$PC_LABEL.plist" "$AGENTS/$BR_LABEL.plist"
  echo "Removed. Paperclip and the bridge will no longer start at login."
  exit 0
fi

[ "$(uname)" = "Darwin" ] || { echo "LaunchAgents are macOS only. On Linux use a systemd user unit; on Windows a scheduled task." >&2; exit 1; }
[ -f "$HERE/.env" ] || { echo "Run ./Scripts/paperclip/up.sh once first (it writes .env)." >&2; exit 1; }
[ -f "$HERE/.connection.json" ] || { echo "Run bootstrap.mjs with your token first (it writes .connection.json)." >&2; exit 1; }
NODE="$(command -v node || true)"; NPX="$(command -v npx || true)"
[ -n "$NODE" ] && [ -n "$NPX" ] || { echo "Node.js 20+ is required (https://nodejs.org)." >&2; exit 1; }

# .env → <key>…</key><string>…</string> pairs for the Paperclip agent.
ENV_XML=""
while IFS='=' read -r k v; do
  case "$k" in ''|\#*) continue ;; esac
  v="${v%\"}"; v="${v#\"}"
  ENV_XML="$ENV_XML
      <key>$k</key><string>$(printf '%s' "$v" | sed 's/&/\&amp;/g; s/</\&lt;/g')</string>"
done < "$HERE/.env"

cat > "$AGENTS/$PC_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$PC_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$NPX</string><string>--yes</string><string>paperclipai</string><string>run</string>
    <string>--bind</string><string>loopback</string><string>--instance</string><string>nohands</string>
  </array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>EnvironmentVariables</key><dict>
      <key>PATH</key><string>$(dirname "$NODE"):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>$ENV_XML
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HERE/data/paperclip.log</string>
  <key>StandardErrorPath</key><string>$HERE/data/paperclip.log</string>
</dict></plist>
PLIST

cat > "$AGENTS/$BR_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$BR_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$NODE</string><string>$HERE/bridge.mjs</string>
  </array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>EnvironmentVariables</key><dict>
      <key>PATH</key><string>$(dirname "$NODE"):/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HERE/data/bridge.log</string>
  <key>StandardErrorPath</key><string>$HERE/data/bridge.log</string>
</dict></plist>
PLIST

# Stop the ad-hoc copies up.sh may have started, then hand over to launchd.
"$HERE/up.sh" down >/dev/null 2>&1 || true
unload "$PC_LABEL"; unload "$BR_LABEL"
launchctl bootstrap "gui/$(id -u)" "$AGENTS/$PC_LABEL.plist"
launchctl bootstrap "gui/$(id -u)" "$AGENTS/$BR_LABEL.plist"
echo "Installed. Paperclip and the bridge now start at login and restart if they stop."
echo "Check: ./Scripts/paperclip/up.sh status    Logs: $HERE/data/*.log"
